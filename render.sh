#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Benoît Dupont de Dinechin
# SPDX-License-Identifier: Apache-2.0
# render.sh — render a project's Markdown as HTML preview or dated PDF.
#
# Uses pandoc, and xelatex for PDF. It makes no network calls: several of the projects that use
# this hold sensitive or unpublished material, and rendering must never be the thing that sends a
# document somewhere. (It replaces `grip`, which renders by POSTing the file to GitHub.)
#
#   render.sh                   the project's default documents, as HTML
#   render.sh --pdf             the same, as PDF
#   render.sh --all --pdf       a named fileset, as PDF
#   render.sh a.md b.md         render the named files
#   render.sh --open ...        also open the first result
#   render.sh -o DIR ...        output directory
#   render.sh --force ...       rebuild even where the source is unchanged
#   render.sh --project DIR     the project to read docbuild.conf from (default: $PWD)
#
# PDF filenames carry the build date — Output_Design_Note_20260903.pdf — so successive
# builds sit side by side rather than overwriting each other, and the reader can tell which
# version they were sent. HTML previews are transient and keep a stable name.
#
# A PDF is rebuilt only when its Markdown has changed since the last build, tracked by content
# hash in .build-manifest beside the output. A date stamp therefore marks the day the document
# changed rather than the day someone ran the script. The hash covers the Markdown alone, so
# use --force after editing the LaTeX preamble or upgrading pandoc.

set -euo pipefail
PKG="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$PKG/lib/project.sh"
source "$PKG/lib/build-cache.sh"

# --project is read first: the conf declares the filesets that the rest of the arguments name.
PROJECT_DIR="$PWD"
args=("$@"); for i in "${!args[@]}"; do
  [[ "${args[$i]}" == "--project" ]] && PROJECT_DIR="${args[$((i+1))]}"
done
project_load "$PROJECT_DIR"

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  [[ -n "$DOC_ABOUT" ]] && printf '\nProject: %s\n' "$DOC_ABOUT"
  printf 'Filesets: %s\n' "$(project_filesets | sed 's/^/--/' | tr '\n' ' ')"
}

OUTDIR=""; OPEN=0; PDF=0; FORCE=0; FILES=()
while (( $# )); do
  case "$1" in
    --pdf)     PDF=1 ;;
    --open)    OPEN=1 ;;
    --force)   FORCE=1 ;;
    --project) shift ;;
    -o)        shift; OUTDIR="$1" ;;
    -h|--help) usage; exit 0 ;;
    --*)       name="${1#--}"
               project_has_fileset "$name" || { echo "render.sh: no such option or fileset: $1" >&2; exit 2; }
               while IFS= read -r f; do FILES+=("$f"); done < <(project_fileset "$name") ;;
    *)         FILES+=("$1") ;;
  esac
  shift
done

if (( ! ${#FILES[@]} )); then
  project_has_fileset default || { echo "render.sh: $PROJECT/docbuild.conf declares no fileset_default" >&2; exit 1; }
  while IFS= read -r f; do FILES+=("$f"); done < <(project_fileset default)
fi
[[ -n "$OUTDIR" ]] || { (( PDF )) && OUTDIR="$(project_pdf_outdir)" || OUTDIR="$(project_html_outdir)"; }

command -v pandoc >/dev/null || { echo "render.sh: pandoc is not installed" >&2; exit 1; }
(( PDF )) && { command -v xelatex >/dev/null || { echo "render.sh: --pdf needs xelatex" >&2; exit 1; }; }
mkdir -p "$OUTDIR"
(( PDF )) && cache_init "$OUTDIR"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STAMP="$(date +%Y%m%d)"
STYLE="${HTML_STYLE:-$PKG/assets/style.html}"
HEADER="${PDF_HEADER:-$PKG/assets/header.tex}"

rendered=()
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { echo "render.sh: no such file: $f" >&2; continue; }
  rel="${f#"$PROJECT"/}"
  stem="$(echo "${rel%.md}" | tr '/' '_')"

  if (( PDF )); then
    hash="$(cache_hash "$f")"
    if (( ! FORCE )); then
      # already built from this exact content, or built before the manifest existed
      if have="$(cache_current "$stem.pdf" "$hash" "$OUTDIR")" \
         || { have="$(cache_adopt "$stem.pdf" "$OUTDIR" "${stem}_[0-9]*.pdf" "$f")" \
              && cache_record "$stem.pdf" "$hash" "$have"; }; then
        printf '  %-42s == %s\n' "$rel" "$have"
        rendered+=("$OUTDIR/$have")
        continue
      fi
    fi
    # xelatex has no colour-emoji font: swap the glyphs it cannot set, and drop variation
    # selectors (U+FE0F) that would otherwise print as tofu.
    sed -e 's/⭐/★/g' -e 's/✅/✓/g' -e 's/⛔/✗/g' \
        -e 's/❓/?/g'  -e 's/➡️/→/g' -e 's/➡/→/g' \
        -e $'s/️//g' "$f" > "$TMP/in.md"
    out="$OUTDIR/${stem}_$STAMP.pdf"
    pandoc -f gfm "$TMP/in.md" -o "$out" \
      --lua-filter="$PKG/assets/colwidths.lua" --include-in-header="$HEADER" \
      --pdf-engine=xelatex --toc --toc-depth=3 \
      -V mainfont="DejaVu Sans" -V monofont="DejaVu Sans Mono" \
      -V geometry:a4paper -V geometry:margin=1.8cm -V fontsize=10pt \
      -V colorlinks=true -V linkcolor=blue -V urlcolor=blue \
      --metadata title="$rel" "${PDF_OPTS[@]+"${PDF_OPTS[@]}"}"
    cache_record "$stem.pdf" "$hash" "$(basename "$out")"
  else
    out="$OUTDIR/$stem.html"
    pandoc -f gfm "$f" -o "$out" -t html5 --standalone --toc --toc-depth=3 \
      --metadata title="$rel" --include-in-header="$STYLE"
  fi
  printf '  %-42s -> file://%s\n' "$rel" "$out"
  rendered+=("$out")
done

(( ${#rendered[@]} )) || exit 1
if (( OPEN )); then
  command -v xdg-open >/dev/null && xdg-open "${rendered[0]}" >/dev/null 2>&1 || true
fi
