#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Benoît Dupont de Dinechin
# SPDX-License-Identifier: Apache-2.0
# build-pptx.sh — build an editable .pptx from a project's slide-content Markdown.
#
# Companion to build-slides.sh, which produces the beamer PDF from the same source and with the
# same slide breaks. The difference is what happens to the diagrams: the PDF embeds them as
# vector art, this one redraws them as native PowerPoint shapes (lib/svg2pptx.py), so each box,
# arrow and label can be selected, recoloured and restyled — which is what a house template
# demands. Uses pandoc and python-pptx only; no network calls.
#
#   build-pptx.sh                -> <name>_YYYYMMDD.pptx
#   build-pptx.sh -o DIR         output directory
#   build-pptx.sh --force        rebuild even where the sources are unchanged
#   build-pptx.sh --project DIR
#
# Rebuilt only when the slide content or a diagram has changed, on the same terms as the PDF
# builds — see lib/build-cache.sh.
#
# Formatting is deliberately plain: pandoc's stock pptx layouts, no theme. The deck is a content
# carrier for a template reformat, not a finished visual design. Speaker notes travel in the
# notes pane; tables come across as real PowerPoint tables.

set -euo pipefail
PKG="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$PKG/lib/project.sh"
source "$PKG/lib/build-cache.sh"

PROJECT_DIR="$PWD"
args=("$@"); for i in "${!args[@]}"; do
  [[ "${args[$i]}" == "--project" ]] && PROJECT_DIR="${args[$((i+1))]}"
done
project_load "$PROJECT_DIR"

OUTDIR=""; FORCE=0
while (( $# )); do
  case "$1" in
    --force)   FORCE=1 ;;
    --project) shift ;;
    -o)        shift; OUTDIR="$1" ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "build-pptx.sh: unknown argument $1" >&2; exit 2 ;;
  esac; shift
done

if [[ -z "${SLIDES_SRC:-}" ]]; then
  echo "build-pptx.sh: this project has no slide deck — docbuild.conf sets no SLIDES_SRC." >&2
  echo "  A deck is one Markdown file carrying both the slides and the speaker notes;" >&2
  echo "  see the slides section of $PKG/docbuild.conf.example." >&2
  exit 1
fi
SRC="$PROJECT/$SLIDES_SRC"
DIAGRAMS="$PROJECT/${DIAGRAMS_DIR:-docs/diagrams}"
NAME="${SLIDES_NAME:-slides}"
if [[ -z "$OUTDIR" ]]; then
  OUTDIR="${PPTX_OUTDIR:-docs/pptx}"
  [[ "$OUTDIR" == /* ]] || OUTDIR="$PROJECT/$OUTDIR"
fi
command -v pandoc >/dev/null || { echo "build-pptx.sh: pandoc not installed" >&2; exit 1; }
python3 -c 'import pptx' 2>/dev/null \
  || { echo "build-pptx.sh: python-pptx not installed (pip install python-pptx)" >&2; exit 1; }
mkdir -p "$OUTDIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STAMP="$(date +%Y%m%d)"
OUT="$OUTDIR/${NAME}_$STAMP.pptx"

cache_init "$OUTDIR"
SOURCES=("$SRC")
if [[ -d "$DIAGRAMS" ]]; then
  while IFS= read -r f; do SOURCES+=("$f"); done \
    < <(find "$DIAGRAMS" -maxdepth 1 -name 'D*.svg' | sort)
fi
HASH="$(cache_hash "${SOURCES[@]}")"
if (( ! FORCE )); then
  if have="$(cache_current "$NAME.pptx" "$HASH" "$OUTDIR")" \
     || { have="$(cache_adopt "$NAME.pptx" "$OUTDIR" "${NAME}_[0-9]*.pptx" "${SOURCES[@]}")" \
          && cache_record "$NAME.pptx" "$HASH" "$have"; }; then
    printf '  %-46s == %s\n' "$NAME" "$have"
    exit 0
  fi
fi

# --- preprocess: same slide breaks as build-slides.sh, diagrams become placeholder slides ---
python3 - "$SRC" "$TMP/deck.md" "$DIAGRAMS" <<'ENDPY'
import os, re, sys
src, dst, diagdir = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()

# A deck file may open with its own title and a note to the author; the deck itself starts at the
# first part divider or slide after that.
lines = text.split('\n')
start = next((i for i, ln in enumerate(lines)
              if i > 0 and (ln.startswith('# ') or ln.startswith('## '))), 0)
text = '\n'.join(lines[start:])


def hoist_list(body):
    """Put a bullet list ahead of a table on the same slide.

    pandoc's pptx writer puts a table alone on a slide and pushes anything that follows it onto a
    second, untitled one — taking the speaker notes with it. Listing first avoids the split: pandoc
    then picks the Content-with-Caption layout and keeps the slide whole. The beamer deck has no
    such constraint and keeps the source order.
    """
    lines = body.split('\n')
    table = [i for i, ln in enumerate(lines) if ln.startswith('|')]
    bullets = [i for i, ln in enumerate(lines) if ln.startswith('- ')]
    if not table or not bullets or bullets[0] < table[0]:
        return body
    lo, hi = min(table), max(table)
    kept = [ln for i, ln in enumerate(lines) if not lo <= i <= hi]
    return '\n'.join(kept).strip() + '\n\n' + '\n'.join(lines[lo:hi + 1]) + '\n'


out, seen = [], set()
for block in re.split(r'(?m)^(?=#{1,2} )', text):
    if not block.strip():
        continue
    head = block.splitlines()[0]

    if head.startswith('# '):                      # part divider
        out.append(head.rstrip() + '\n')
        continue

    # slide: "## 9 — The cluster boundary    ·    D2"
    m = re.match(r'## (.+?)(?:\s+·\s+(D\d))?\s*$', head)
    title, diag = m.group(1).strip(), m.group(2)
    body = block[len(head):]

    body = body.replace('**On slide**\n', '')
    if '**Notes**' in body:                        # -> pandoc speaker-note div
        on, notes = body.split('**Notes**', 1)
        body = hoist_list(on).rstrip() + '\n\n::: notes\n' + notes.strip() + '\n:::\n'
    else:
        body = hoist_list(body)
    body = re.sub(r'(?m)^---\s*$', '', body)

    out.append(f'## {title}\n{body}\n')

    # a bare title is the hook the post-pass finds; the shapes are drawn onto it afterwards
    if diag and diag not in seen and os.path.isdir(diagdir) and any(
            f.startswith(diag + '-') for f in os.listdir(diagdir)):
        seen.add(diag)
        out.append(f'## {diag}\n\n')

open(dst, 'w').write('\n'.join(out))
ENDPY

pandoc "$TMP/deck.md" -t pptx --slide-level=2 -o "$TMP/deck.pptx"

# --- post-process: redraw each diagram slide as native shapes ---
DECK_TITLE="${SLIDES_TITLE:-$NAME}" DECK_SUBTITLE="${SLIDES_SUBTITLE:-}" \
PYTHONPATH="$PKG/lib" python3 - "$TMP/deck.pptx" "$OUT" "$DIAGRAMS" <<'ENDPY'
import glob, os, re, sys
from pptx import Presentation
import svg2pptx

deck, out, diagdir = sys.argv[1:4]
prs = Presentation(deck)
MARGIN = 182880                                    # 0.2in, in EMU
box = (MARGIN, MARGIN, prs.slide_width - 2 * MARGIN, prs.slide_height - 2 * MARGIN)

# pandoc uses Content-with-Caption when a slide carries both a list and a table, which parks the
# title in the left column. Restore a title band and turn the rest into two columns.
TITLE = (457200, 205979, prs.slide_width - 914400, 857250)
BODY_TOP = 1193800
for slide in prs.slides:
    if slide.slide_layout.name != 'Content with Caption':
        continue
    for shape in slide.shapes:
        # placeholders inherit geometry from the layout, so all four values must be written
        left, top, width, height = shape.left, shape.top, shape.width, shape.height
        if shape.is_placeholder and shape.placeholder_format.idx == 0:
            left, top, width, height = TITLE
        else:
            top, height = BODY_TOP, min(height, prs.slide_height - BODY_TOP - MARGIN)
        shape.left, shape.top, shape.width, shape.height = left, top, width, height

drawn = 0
for slide in prs.slides:
    titles = [s for s in slide.shapes
              if s.has_text_frame and re.fullmatch(r'D\d', s.text_frame.text.strip())]
    if not titles:
        continue
    key = titles[0].text_frame.text.strip()
    matches = glob.glob(os.path.join(diagdir, key + '-*.svg'))
    if not matches:
        continue
    for shape in list(slide.shapes):               # a full-bleed diagram carries its own title
        shape._element.getparent().remove(shape._element)
    n = svg2pptx.draw(matches[0], slide, box)
    print(f'  {os.path.basename(matches[0])}  ->  {n} shapes')
    drawn += 1

# PowerPoint's own document properties: pandoc leaves these empty.
cp = prs.core_properties
cp.title = os.environ.get('DECK_TITLE') or 'Slides'
if os.environ.get('DECK_SUBTITLE'):
    cp.subject = os.environ['DECK_SUBTITLE']

prs.save(out)
print(f'\n  {len(prs.slides._sldIdLst)} slides, {drawn} diagrams as native shapes')
ENDPY

cache_record "$NAME.pptx" "$HASH" "$(basename "$OUT")"
printf '\n  %-46s -> file://%s\n' "$(basename "$OUT")" "$OUT"
