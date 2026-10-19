#!/usr/bin/env bash
# build-latex.sh — build a project's LaTeX documents, rebuilding only what has changed.
#
# For projects where LaTeX rather than Markdown is the master: a directory of documents that
# share a style file, each producing one PDF. Uses the configured engine only; no network calls.
#
#   build-latex.sh               every document in LATEX_DIR
#   build-latex.sh a.tex b.tex   only the named documents
#   build-latex.sh --force       rebuild even where the sources are unchanged
#   build-latex.sh --strict      exit non-zero if the folio check finds an overrun
#   build-latex.sh -o DIR        output directory
#   build-latex.sh --project DIR
#
# A document is every `.tex` in LATEX_DIR that declares a `\documentclass`; the rest — a shared
# style file, fragments meant to be `\input` — are treated as includes. A document's sources are
# its own file plus every include in the directory, so a change to the shared style rebuilds all
# of them and a change to one document rebuilds only that one.
#
# Output names follow the source by default — `Report_Alpha.tex` gives
# `Report_Alpha.pdf` — because a LaTeX deliverable is usually referred to by a name that
# has to stay put. Set LATEX_STAMP=date for the dated names the Markdown builds use.
#
# The engine runs LATEX_PASSES times (three, by default: `longtable` column widths need a third
# pass to settle). Intermediate files are written to a temporary directory, so the source tree
# keeps only the sources and the PDFs.
#
# With LATEX_FOLIO_CHECK set, each built PDF is checked for text that has run into the bottom
# margin — the silent failure mode of a `longtable` row too tall to fit the page. See
# lib/folio_check.py.

set -euo pipefail
PKG="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$PKG/lib/project.sh"
source "$PKG/lib/build-cache.sh"

PROJECT_DIR="$PWD"
args=("$@"); for i in "${!args[@]}"; do
  [[ "${args[$i]}" == "--project" ]] && PROJECT_DIR="${args[$((i+1))]}"
done
project_load "$PROJECT_DIR"

OUTDIR=""; FORCE=0; STRICT=0; NAMED=()
while (( $# )); do
  case "$1" in
    --force)   FORCE=1 ;;
    --strict)  STRICT=1 ;;
    --project) shift ;;
    -o)        shift; OUTDIR="$1" ;;
    -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        echo "build-latex.sh: unknown option $1" >&2; exit 2 ;;
    *)         NAMED+=("$1") ;;
  esac; shift
done

if [[ -z "${LATEX_DIR:-}" ]]; then
  echo "build-latex.sh: this project has no LaTeX documents — docbuild.conf sets no LATEX_DIR." >&2
  echo "  See the LaTeX section of $PKG/docbuild.conf.example." >&2
  exit 1
fi
SRCDIR="$PROJECT/$LATEX_DIR"
[[ -d "$SRCDIR" ]] || { echo "build-latex.sh: no such directory: $SRCDIR" >&2; exit 1; }
ENGINE="${LATEX_ENGINE:-pdflatex}"
PASSES="${LATEX_PASSES:-3}"
command -v "$ENGINE" >/dev/null || { echo "build-latex.sh: $ENGINE not installed" >&2; exit 1; }

# Output sits beside the sources unless the conf or -o says otherwise.
if [[ -z "$OUTDIR" ]]; then
  OUTDIR="${LATEX_OUTDIR:-$SRCDIR}"
  [[ "$OUTDIR" == /* ]] || OUTDIR="$PROJECT/$OUTDIR"
fi
mkdir -p "$OUTDIR"
cache_init "$OUTDIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STAMP="$(date +%Y%m%d)"

# --- documents and includes ---
DOCS=(); INCLUDES=()
for tex in "$SRCDIR"/*.tex; do
  [[ -e "$tex" ]] || continue
  if grep -q '\\documentclass' "$tex"; then DOCS+=("$tex"); else INCLUDES+=("$tex"); fi
done
(( ${#DOCS[@]} )) || { echo "build-latex.sh: no \\documentclass found in $SRCDIR/*.tex" >&2; exit 1; }
if (( ${#NAMED[@]} )); then                        # restrict to the documents named on the line
  keep=()
  for want in "${NAMED[@]}"; do
    want="$(basename "$want" .tex)"
    for doc in "${DOCS[@]}"; do
      [[ "$(basename "$doc" .tex)" == "$want" ]] && keep+=("$doc")
    done
  done
  (( ${#keep[@]} )) || { echo "build-latex.sh: none of the named documents are in $SRCDIR" >&2; exit 1; }
  DOCS=("${keep[@]}")
fi

built=()
for doc in "${DOCS[@]}"; do
  stem="$(basename "$doc" .tex)"
  name="$stem"; [[ "${LATEX_STAMP:-}" == "date" ]] && name="${stem}_$STAMP"
  glob="$stem.pdf"; [[ "${LATEX_STAMP:-}" == "date" ]] && glob="${stem}_[0-9]*.pdf"
  hash="$(cache_hash "$doc" ${INCLUDES[@]+"${INCLUDES[@]}"})"

  if (( ! FORCE )); then
    if have="$(cache_current "$stem.pdf" "$hash" "$OUTDIR")" \
       || { have="$(cache_adopt "$stem.pdf" "$OUTDIR" "$glob" "$doc" ${INCLUDES[@]+"${INCLUDES[@]}"})" \
            && cache_record "$stem.pdf" "$hash" "$have"; }; then
      printf '  %-40s == %s\n' "$stem.tex" "$have"
      built+=("$OUTDIR/$have")
      continue
    fi
  fi

  # Run from the source directory so \input resolves as it does by hand, but write the aux files
  # to a scratch directory so the tree keeps only sources and PDFs.
  mkdir -p "$TMP/$stem"
  for (( pass = 1; pass <= PASSES; pass++ )); do
    ( cd "$SRCDIR" && "$ENGINE" -interaction=nonstopmode -halt-on-error \
        -output-directory="$TMP/$stem" "$stem.tex" ) > "$TMP/$stem/pass$pass.log" 2>&1 || {
      echo "build-latex.sh: $ENGINE failed on $stem.tex (pass $pass)" >&2
      sed -n '/^!/,+6p' "$TMP/$stem/$stem.log" 2>/dev/null | head -20 >&2
      exit 1
    }
  done
  cp "$TMP/$stem/$stem.pdf" "$OUTDIR/$name.pdf"
  cache_record "$stem.pdf" "$hash" "$name.pdf"
  printf '  %-40s -> file://%s\n' "$stem.tex" "$OUTDIR/$name.pdf"
  built+=("$OUTDIR/$name.pdf")
done

# --- folio check ---
# A longtable row taller than the space left on the page is not split; it runs over the folio and
# LaTeX reports nothing. Catch it here rather than by reading every page.
if [[ -n "${LATEX_FOLIO_CHECK:-}" ]] && (( ${#built[@]} )); then
  if command -v pdftotext >/dev/null; then
    read -r lo hi <<< "${LATEX_FOLIO_BAND:-727 748}"
    if ! python3 "$PKG/lib/folio_check.py" "$lo" "$hi" "${built[@]}" > "$TMP/folio.txt"; then
      echo
      echo "  folio overrun — a longtable row has run into the bottom margin."
      echo "  Split the offending cell with \\ContRow{...}:"
      cat "$TMP/folio.txt"
      (( STRICT )) && exit 1
    fi
  else
    echo "  (folio check skipped: pdftotext not installed)" >&2
  fi
fi
