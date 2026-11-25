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
# Formatting is deliberately plain: pandoc's stock pptx layouts on a widescreen reference, no
# theme. The deck is a content
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

OUTDIR=""; FORCE=0; KEEP_OLD=0
while (( $# )); do
  case "$1" in
    --force)   FORCE=1 ;;
    --keep-old) KEEP_OLD=1 ;;
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
(cd / && python3 -c 'import pptx') 2>/dev/null \
  || { echo "build-pptx.sh: python-pptx not installed (pip install python-pptx)" >&2; exit 1; }
mkdir -p "$OUTDIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STAMP="$(date +%Y%m%d)"
OUT="$OUTDIR/${NAME}_$STAMP.pptx"

cache_init "$OUTDIR"
SOURCES=("$SRC")
if [[ -d "$DIAGRAMS" ]]; then
  while IFS= read -r f; do SOURCES+=("$f"); done \
    < <(find "$DIAGRAMS" -maxdepth 1 -name '[DF][0-9]*.svg' | sort)
fi
# Syntax highlighting. pandoc colours a fenced block tagged with a language it knows; a language
# it does not know (an ISA's assembly, an MLIR dialect) comes from a KDE syntax definition, and
# SLIDES_SYNTAX_DIR names a directory of them. They are sources like the deck: a changed grammar
# re-colours the deck, so they enter the cache hash too.
HL_ARGS=(--highlight-style="${SLIDES_HIGHLIGHT_STYLE:-pygments}")
if [[ -n "${SLIDES_SYNTAX_DIR:-}" ]]; then
  SYNDIR="$SLIDES_SYNTAX_DIR"; [[ "$SYNDIR" == /* ]] || SYNDIR="$PROJECT/$SYNDIR"
  [[ -d "$SYNDIR" ]] || { echo "${0##*/}: SLIDES_SYNTAX_DIR is not a directory: $SYNDIR" >&2; exit 1; }
  while IFS= read -r f; do HL_ARGS+=(--syntax-definition="$f"); SOURCES+=("$f"); done \
    < <(find "$SYNDIR" -maxdepth 1 -name '*.xml' | sort)
fi
HASH="$(cache_hash "${SOURCES[@]}")"
if (( ! FORCE )); then
  if have="$(cache_current "$NAME.pptx" "$HASH" "$OUTDIR")" \
     || { have="$(cache_adopt "$NAME.pptx" "$OUTDIR" "${NAME}_[0-9]*.pptx" "${SOURCES[@]}")" \
          && cache_record "$NAME.pptx" "$HASH" "$have" "$SLIDES_SRC"; }; then
    # A hit on an entry predating recorded provenance: the content matches, so the
    # source is known. Fill it in rather than wait for the next real rebuild.
    [[ -n "$(cache_sources "$NAME.pptx")" ]] \
      || cache_record "$NAME.pptx" "$HASH" "$have" "$SLIDES_SRC"
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

    # slide: "## 9 — The cluster boundary    ·    F2"
    m = re.match(r'## (.+?)(?:\s+·\s+([DF]\d+))?\s*$', head)
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

# Pandoc takes the slide size from its reference document, and its default is 10x5.625in.
# That is 16:9, but small: a slide dense enough to read as a beamer frame overflows the body
# placeholder, and PowerPoint does not autofit it -- the last bullets simply fall off. Widen the
# reference to 13.333x7.5, the size PowerPoint itself calls Widescreen, which is the same aspect
# and 78% more area at the same point size. Generated from pandoc's own default so there is no
# binary in this package to drift.
pandoc --print-default-data-file reference.pptx > "$TMP/ref.pptx"
python3 - "$TMP/ref.pptx" <<'REFPY'
import sys
from pptx import Presentation
from pptx.util import Inches
prs = Presentation(sys.argv[1])
old_w, old_h = prs.slide_width, prs.slide_height
prs.slide_width, prs.slide_height = Inches(13.333), Inches(7.5)
# The placeholders are positioned in EMU, not relative to the slide, so widening the slide alone
# leaves every title and body box at its old geometry, hugging the left of the new slide. Scale
# each one that carries its own position; a layout placeholder without one inherits the master's.
sx, sy = prs.slide_width / old_w, prs.slide_height / old_h
for owner in [prs.slide_master, *prs.slide_layouts]:
    for ph in owner.placeholders:
        if ph._element.spPr.find(
                '{http://schemas.openxmlformats.org/drawingml/2006/main}xfrm') is None:
            continue
        ph.left, ph.top = int(ph.left * sx), int(ph.top * sy)
        ph.width, ph.height = int(ph.width * sx), int(ph.height * sy)
prs.save(sys.argv[1])
REFPY
pandoc "$TMP/deck.md" -t pptx --slide-level=2 --reference-doc="$TMP/ref.pptx" "${HL_ARGS[@]}" \
  -o "$TMP/deck.pptx"

# --- post-process: redraw each diagram slide as native shapes ---
DECK_TITLE="${SLIDES_TITLE:-$NAME}" DECK_SUBTITLE="${SLIDES_SUBTITLE:-}" \
PYTHONPATH="$PKG/lib" python3 - "$TMP/deck.pptx" "$OUT" "$DIAGRAMS" <<'ENDPY'
import glob, os, re, sys, tempfile
from pptx import Presentation
from pptx.util import Pt
import figtitle
import svg2pptx

tmpdir = tempfile.mkdtemp()

deck, out, diagdir = sys.argv[1:4]
prs = Presentation(deck)
MARGIN = 182880                                    # 0.2in, in EMU
box = (MARGIN, MARGIN, prs.slide_width - 2 * MARGIN, prs.slide_height - 2 * MARGIN)
FIG_TOP = 1100000                                  # below the title band
fig_box = (MARGIN, FIG_TOP, prs.slide_width - 2 * MARGIN, prs.slide_height - FIG_TOP - MARGIN)

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

# Code blocks. pandoc writes a fenced block as one bullet-less paragraph of Courier runs at the
# body text size and with no autofit, so a 15-line listing runs off the slide. Its lines are
# separated by literal newlines inside a run (pandoc 2.9, where PowerPoint does not break on them
# at all) or by <a:br/> (pandoc 3), and a highlighted block is one run per token, each with its
# own colour and weight. Every line becomes runs separated by <a:br/>, each run keeping its
# colour, bold and italic, at a size fitted to the box: narrow enough for the longest line, short
# enough for the code plus an estimate of the prose around it. That prose is set to 20pt on such
# a slide -- the master's 28pt leaves a listing a third of the box -- so the estimate is not a
# guess about inherited sizes. Every other body box gets normAutofit, which LibreOffice and
# PowerPoint use to shrink a bullet list that overflows.
from lxml import etree
from pptx.oxml.ns import qn
import copy

COURIER = qn('a:rPr') + '/' + qn('a:latin')


def is_code(p):
    ppr, runs = p.find(qn('a:pPr')), p.findall(qn('a:r'))
    return (ppr is not None and ppr.find(qn('a:buNone')) is not None and bool(runs)
            and all(r.find(COURIER) is not None
                    and r.find(COURIER).get('typeface') == 'Courier' for r in runs))


def para_text(p):
    return ''.join(t.text or '' for t in p.iter(qn('a:t')))


def code_lines(p):
    """The paragraph as lines of (rPr, text) segments, whichever way pandoc broke them."""
    lines = [[]]
    for el in p:
        if el.tag == qn('a:br'):
            lines.append([])
        elif el.tag == qn('a:r'):
            rpr, text = el.find(qn('a:rPr')), ''.join(t.text or '' for t in el.iter(qn('a:t')))
            for i, piece in enumerate(text.split('\n')):
                if i:
                    lines.append([])
                if piece:
                    lines[-1].append((rpr, piece))
    while len(lines) > 1 and not lines[-1]:
        lines.pop()
    return lines


def code_rpr(sz, like=None):
    """Courier New at SZ, keeping the colour, bold and italic of the token's own rPr."""
    rpr = etree.Element(qn('a:rPr'), sz=sz)
    if like is not None:
        for attr in ('b', 'i'):
            if like.get(attr) is not None:
                rpr.set(attr, like.get(attr))
        fill = like.find(qn('a:solidFill'))
        if fill is not None:
            rpr.append(copy.deepcopy(fill))
    etree.SubElement(rpr, qn('a:latin'), typeface='Courier New')
    return rpr


EMU_PT, INSET, PROSE_PT = 12700, 2 * 91440, 20
for slide in prs.slides:
    for shape in slide.shapes:
        if not shape.has_text_frame or (shape.is_placeholder
                                        and shape.placeholder_format.idx == 0):
            continue
        body = shape.text_frame._txBody
        bodypr = body.find(qn('a:bodyPr'))
        paras = body.findall(qn('a:p'))
        code = [p for p in paras if is_code(p)]
        # A box holding code has its sizes fitted below, so it says noAutofit outright: the
        # master's bodyPr carries normAutofit, and LibreOffice's shrink is coarse enough to scale
        # a box that only just overflows down to half its size.
        if bodypr is not None and not len(bodypr):
            etree.SubElement(bodypr, qn('a:noAutofit' if code else 'a:normAutofit'))
        if not code or not shape.width or not shape.height:
            continue
        w_pt = (shape.width - INSET) / EMU_PT
        h_pt = (shape.height - INSET) / EMU_PT
        blocks = [code_lines(p) for p in code]
        for p in paras:
            if p not in code:
                for rpr in p.iter(qn('a:rPr'), qn('a:endParaRPr')):
                    rpr.set('sz', str(PROSE_PT * 100))
        widest = max(len(''.join(t for _, t in ln).expandtabs(8)) for b in blocks for ln in b)
        nlines = sum(len(b) for b in blocks)
        # prose wrapped at half an em per character, 1.2 line height, plus paragraph spacing
        per_line = max(1, int(w_pt / (0.5 * PROSE_PT)))
        prose = sum(1.2 * PROSE_PT * -(-len(para_text(p)) // per_line) + 6
                    for p in paras if p not in code and para_text(p).strip())
        size = min(14.0, w_pt / (0.6 * max(widest, 1)),
                   max(h_pt - prose, h_pt / 3) / (1.2 * nlines + 0.5 * len(code)))
        sz = str(int(max(7.0, size) * 2) * 50)    # hundredths of a point, in half-point steps
        for p, lines in zip(code, blocks):
            for el in p.findall(qn('a:r')) + p.findall(qn('a:br')):
                p.remove(el)
            end = p.find(qn('a:endParaRPr'))
            if end is not None:
                p.remove(end)
            for i, ln in enumerate(lines):
                if i:
                    etree.SubElement(p, qn('a:br')).append(code_rpr(sz))
                for rpr, text in ln or [(None, '')]:
                    r = etree.SubElement(p, qn('a:r'))
                    r.append(code_rpr(sz, rpr))
                    etree.SubElement(r, qn('a:t')).text = text
            if end is not None:                        # the schema wants it last
                p.append(end)

drawn = 0
for slide in prs.slides:
    titles = [s for s in slide.shapes
              if s.has_text_frame and re.fullmatch(r'[DF]\d+', s.text_frame.text.strip())]
    if not titles:
        continue
    key = titles[0].text_frame.text.strip()
    matches = glob.glob(os.path.join(diagdir, key + '-*.svg'))
    if not matches:
        continue
    # The figure's own "F3 — ..." title goes in the title placeholder and is lifted out of the
    # drawing (lib/figtitle.py), so it is not shown twice. Without one, the diagram is drawn
    # full-bleed and carries its own title, as before.
    stripped = os.path.join(tmpdir, key + '.svg')
    ftitle = figtitle.strip(matches[0], stripped)
    for shape in list(slide.shapes):
        if ftitle and shape._element is titles[0]._element:   # proxies differ, elements do not
            continue
        shape._element.getparent().remove(shape._element)
    if ftitle:
        tf = titles[0].text_frame
        tf.text = ftitle
        for run in tf.paragraphs[0].runs:
            run.font.size = Pt(24)
        n = svg2pptx.draw(stripped, slide, fig_box)
    else:
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

cache_record "$NAME.pptx" "$HASH" "$(basename "$OUT")" "$SLIDES_SRC"
printf '\n  %-46s -> file://%s\n' "$(basename "$OUT")" "$OUT"

# Remove the dated outputs this build supersedes; --keep-old retains them. See cache_prune.
(( KEEP_OLD )) || cache_prune "$OUTDIR"
