#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Benoît Dupont de Dinechin
# SPDX-License-Identifier: Apache-2.0
# doctor.sh — check that this machine has the tools, versions, LaTeX packages and fonts the
# docbuild tools need, then prove it by building a small PDF through the real pipeline.
#
#   doctor.sh                  check what this project uses
#   doctor.sh --all            check every tool group, used or not
#   doctor.sh --quick          skip the test render
#   doctor.sh --project DIR    the project to read docbuild.conf from (default: $PWD)
#
# A group is checked when the project uses it: render always; diagrams when DIAGRAMS_DIR holds
# .dot sources or the project has a build-diagrams.sh wrapper; slides when SLIDES_SRC is set or
# there is a build-slides.sh wrapper; pptx when there is a build-pptx.sh wrapper; deck when there
# is a build-deck.sh wrapper or DECK_OUTDIR is set; latex when LATEX_DIR is set. Exits non-zero if anything required is missing or too old.
#
# The version floors are the oldest releases the scripts actually work with, not the newest
# release tested. Each one names the feature that sets it, so the floor can be revisited when
# that feature goes:
#   pandoc 2.19    --embed-resources (render.sh HTML preview); the Lua table model used by
#                  assets/colwidths.lua dates from 2.10
#   inkscape 1.0   the `-o FILE --export-type=pdf` syntax (build-slides.sh)
#
# A version check cannot see everything. pandoc 3.5 passes the floor and still rejected
# colwidths.lua until it stopped passing a Cell to stringify, so the test render runs the actual
# filter and preamble rather than trusting the numbers. Nothing here touches the network.

set -euo pipefail
PKG="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$PKG/lib/project.sh"

PROJECT_DIR="$PWD"; ALL=0; QUICK=0
while (( $# )); do
  case "$1" in
    --project) shift; PROJECT_DIR="$1" ;;
    --all)     ALL=1 ;;
    --quick)   QUICK=1 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "doctor.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# A project is optional: run from the package itself, with no conf, everything is checked.
if [[ -f "$PROJECT_DIR/docbuild.conf" ]]; then
  project_load "$PROJECT_DIR"
else
  PROJECT=""; ALL=1
fi

FAIL=0
ok()   { printf '  ok       %-20s %s\n' "$1" "$2"; }
warn() { printf '  warn     %-20s %s\n' "$1" "$2"; }
bad()  { printf '  FAIL     %-20s %s\n' "$1" "$2"; FAIL=1; }

# version_ge HAVE NEED — true when HAVE >= NEED, by version-sort order.
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

# need_cmd NAME [WHY] — the command exists. Prints and returns 1 if not.
need_cmd() {
  command -v "$1" >/dev/null && return 0
  bad "$1" "not installed${2:+ — $2}"; return 1
}

# need_version NAME HAVE NEED
need_version() {
  if [[ -z "$2" ]]; then bad "$1" "installed, but its version could not be read"
  elif version_ge "$2" "$3"; then ok "$1" "$2 (needs ≥ $3)"
  else bad "$1" "$2 is too old (needs ≥ $3)"; fi
}

need_sty() {  # PACKAGE.sty|CLASS.cls ...
  local f missing=()
  command -v kpsewhich >/dev/null || { bad "kpsewhich" "not installed — cannot check LaTeX packages"; return; }
  for f in "$@"; do kpsewhich "$f" >/dev/null || missing+=("$f"); done
  if (( ${#missing[@]} )); then bad "LaTeX packages" "missing: ${missing[*]}"
  else ok "LaTeX packages" "$*"; fi
}

need_font() {  # FAMILY
  command -v fc-list >/dev/null || { warn "fonts" "fc-list not installed — cannot check $1"; return; }
  # No pipe into grep -q: under pipefail its early exit fails fc-list with SIGPIPE.
  if [[ -n "$(fc-list ":family=$1" family)" ]]; then ok "font" "$1"
  else bad "font" "$1 not found (fontconfig)"; fi
}

# Which groups this project uses.
uses() {
  (( ALL )) && return 0
  case "$1" in
    render)   return 0 ;;
    diagrams) [[ -x "$PROJECT/build-diagrams.sh" ]] && return 0
              [[ -n "${DIAGRAMS_DIR:-}" ]] && compgen -G "$PROJECT/$DIAGRAMS_DIR/*.dot" >/dev/null ;;
    slides)   [[ -n "${SLIDES_SRC:-}" || -x "$PROJECT/build-slides.sh" ]] ;;
    pptx)     [[ -x "$PROJECT/build-pptx.sh" ]] ;;
    deck)     [[ -x "$PROJECT/build-deck.sh" || -n "${DECK_OUTDIR:-}" ]] ;;
    latex)    [[ -n "${LATEX_DIR:-}" ]] ;;
  esac
}

skipped=()
section() {
  if uses "$1"; then printf '\n%s\n' "$2"; return 0; fi
  skipped+=("$1"); return 1
}

echo "docbuild doctor — package $PKG"
[[ -n "$PROJECT" ]] && echo "project $PROJECT" || echo "no docbuild.conf in $PROJECT_DIR: checking everything"

if section render "render.sh — HTML preview and PDF"; then
  if need_cmd pandoc; then
    need_version pandoc "$(pandoc --version | sed -n '1s/^pandoc[^ ]* \([0-9.]*\).*/\1/p')" 2.19
  fi
  if need_cmd xelatex "the PDF engine"; then
    ok xelatex "$(xelatex --version | head -1)"
  fi
  # The packaged preamble, plus what pandoc's own LaTeX template loads under xelatex.
  need_sty etoolbox.sty fvextra.sty hyphenat.sty ragged2e.sty \
           fontspec.sty unicode-math.sty geometry.sty hyperref.sty xcolor.sty \
           longtable.sty booktabs.sty array.sty calc.sty bookmark.sty upquote.sty
  need_font "DejaVu Sans"
  need_font "DejaVu Sans Mono"
  need_cmd sha256sum "the build manifest hashes sources with it" && ok sha256sum "present"
fi

if section diagrams "build-diagrams.sh — Graphviz to SVG and PDF"; then
  need_cmd dot "Graphviz" && ok dot "$(dot -V 2>&1 | head -1)"
  need_cmd python3 "the SVG subset check" && ok python3 "$(python3 --version 2>&1)"
  # Only an SVG with no .dot beside it needs a converter, so its absence is a warning.
  conv=""; for c in rsvg-convert inkscape cairosvg; do command -v "$c" >/dev/null && { conv="$c"; break; }; done
  [[ -n "$conv" ]] && ok "svg-to-pdf" "$conv" \
    || warn "svg-to-pdf" "none of rsvg-convert, inkscape, cairosvg — needed only for SVGs with no .dot"
fi

if section slides "build-slides.sh — beamer deck"; then
  need_cmd pandoc || true
  need_cmd xelatex || true
  if need_cmd inkscape "diagrams are converted to PDF with it"; then
    need_version inkscape "$(inkscape --version 2>/dev/null | sed -n 's/^Inkscape \([0-9.]*\).*/\1/p' | head -1)" 1.0
  fi
  need_cmd python3 || true
  need_sty beamer.cls longtable.sty booktabs.sty array.sty ragged2e.sty
fi

if section pptx "build-pptx.sh — editable PowerPoint"; then
  need_cmd pandoc || true
  if need_cmd python3; then
    for mod in pptx lxml; do
      if v="$(python3 -P -c "import $mod as m; print(getattr(m, '__version__', '') or getattr(getattr(m, 'etree', None), '__version__', '') or 'present')" 2>/dev/null)"; then
        ok "python: $mod" "$v"
      else
        bad "python: $mod" "not importable — pip install python-pptx"
      fi
    done
  fi
fi

# build-deck.sh measures text with the metrics of the font that will render it, so the font is
# required, not cosmetic: without Carlito, LibreOffice substitutes a face of different widths and
# the PDF no longer matches the layout -- or PowerPoint.
if section deck "build-deck.sh — designed PowerPoint, PDFs exported from it"; then
  need_cmd pandoc "parses the deck source" || true
  need_cmd fc-match "font lookup for text measurement (fontconfig)" && ok fc-match "present"
  if need_cmd python3; then
    for mod in pptx lxml PIL; do
      if v="$(python3 -P -c "import $mod as m; print(getattr(m, '__version__', '') or getattr(getattr(m, 'etree', None), '__version__', '') or 'present')" 2>/dev/null)"; then
        ok "python: $mod" "$v"
      else
        bad "python: $mod" "not importable — pip install python-pptx (it brings lxml and Pillow)"
      fi
    done
  fi
  if command -v soffice >/dev/null || command -v libreoffice >/dev/null; then
    ok "LibreOffice" "$({ soffice --version || libreoffice --version; } 2>/dev/null | head -1)"
  else
    bad "LibreOffice" "not installed — exports the PDFs (apt install libreoffice-impress)"
  fi
  if command -v fc-match >/dev/null; then
    f="$(fc-match -f '%{family}' Calibri 2>/dev/null)"
    case "$f" in
      Carlito*|Calibri*) ok "font" "Calibri → $f" ;;
      *) bad "font" "Calibri resolves to ${f:-nothing} — apt install fonts-crosextra-carlito" ;;
    esac
    f="$(fc-match -f '%{family}' 'Courier New' 2>/dev/null)"
    case "$f" in
      "Liberation Mono"*|"Courier New"*) ok "font" "Courier New → $f" ;;
      *) warn "font" "Courier New resolves to ${f:-nothing} — code will be measured wrongly (fonts-liberation)" ;;
    esac
  fi
fi

if section latex "build-latex.sh — LaTeX documents"; then
  engine="${LATEX_ENGINE:-pdflatex}"
  need_cmd "$engine" "LATEX_ENGINE" && ok "$engine" "$("$engine" --version | head -1)"
  if [[ -n "${LATEX_FOLIO_CHECK:-}" ]]; then
    need_cmd pdftotext "LATEX_FOLIO_CHECK is set (poppler-utils)" && ok pdftotext "present"
    need_cmd python3 || true
  else
    command -v pdftotext >/dev/null && ok pdftotext "present (folio check off)" \
      || warn pdftotext "not installed — only LATEX_FOLIO_CHECK needs it"
  fi
fi

# The test render: the same pandoc invocation shape as render.sh, with the packaged filter and
# preamble, on a document holding what has broken builds before — a pipe table, a fenced block
# with box-drawing, non-ASCII text. Skipped when the static checks already failed, since its
# error would only repeat theirs less clearly.
if uses render && (( ! QUICK )); then
  printf '\ntest render\n'
  if (( FAIL )); then
    warn "render" "skipped — fix the failures above first"
  else
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    cat > "$TMP/t.md" <<'EOF'
# Doctor

*Italic abstract with `code`, ≥ ≤ → and é.*

| Column | Another column with longer text |
|---|---|
| a | b |

```
┌──────┐
│ box  │ → α β
└──────┘
```
EOF
    if pandoc -f gfm "$TMP/t.md" -o "$TMP/t.pdf" \
         --lua-filter="$PKG/assets/colwidths.lua" --include-in-header="$PKG/assets/header.tex" \
         --pdf-engine=xelatex --toc \
         -V mainfont="DejaVu Sans" -V monofont="DejaVu Sans Mono" \
         >"$TMP/log" 2>&1 && [[ -s "$TMP/t.pdf" ]]; then
      ok "render" "markdown → PDF through colwidths.lua and header.tex"
    else
      bad "render" "pandoc/xelatex failed:"
      sed 's/^/             /' "$TMP/log" | head -20
    fi
  fi
fi

echo
(( ${#skipped[@]} )) && echo "not used by this project, not checked: ${skipped[*]} (--all checks them)"
if (( FAIL )); then echo "docbuild doctor: problems found"; exit 1; fi
echo "docbuild doctor: all checks passed"
