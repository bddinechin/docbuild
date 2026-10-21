#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Benoît Dupont de Dinechin
# SPDX-License-Identifier: Apache-2.0
# build-slides.sh — build a beamer deck from a project's slide-content Markdown.
#
# Companion to render.sh, which renders documents. This one renders slides: one frame per
# `## N — Title`, with each diagram inserted as a full-bleed frame after the slide that first
# references it. Uses pandoc, xelatex and inkscape only; no network calls.
#
#   build-slides.sh              both variants
#   build-slides.sh --notes      only the with-notes variant
#   build-slides.sh -o DIR       output directory
#   build-slides.sh --force      rebuild even where the sources are unchanged
#   build-slides.sh --project DIR
#
# Two variants are produced, both date-stamped:
#   <name>_YYYYMMDD.pdf             the deck as presented
#   <name>_notes_YYYYMMDD.pdf       each slide followed by its speaker notes
#
# A variant is rebuilt only when its sources have changed — the slide Markdown and every
# diagram, since a diagram edit changes the deck without touching the Markdown. See
# lib/build-cache.sh.
#
# The source Markdown follows three conventions:
#   `# Part N — ...`               a section divider frame
#   `## N — Title    ·    D2`      a slide; the `· D2` suffix names a diagram in DIAGRAMS_DIR
#   `**On slide**` / `**Notes**`   bullets for the frame, prose for the speaker notes
# The `**On slide**` label is dropped and everything after `**Notes**` becomes speaker notes,
# so one file carries both the deck and what to say over it.

set -euo pipefail
PKG="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$PKG/lib/project.sh"
source "$PKG/lib/build-cache.sh"

PROJECT_DIR="$PWD"
args=("$@"); for i in "${!args[@]}"; do
  [[ "${args[$i]}" == "--project" ]] && PROJECT_DIR="${args[$((i+1))]}"
done
project_load "$PROJECT_DIR"

OUTDIR=""; ONLY_NOTES=0; FORCE=0; KEEP_OLD=0
while (( $# )); do
  case "$1" in
    --notes)   ONLY_NOTES=1 ;;
    --force)   FORCE=1 ;;
    --keep-old) KEEP_OLD=1 ;;
    --project) shift ;;
    -o)        shift; OUTDIR="$1" ;;
    -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "build-slides.sh: unknown argument $1" >&2; exit 2 ;;
  esac; shift
done

if [[ -z "${SLIDES_SRC:-}" ]]; then
  echo "build-slides.sh: this project has no slide deck — docbuild.conf sets no SLIDES_SRC." >&2
  echo "  A deck is one Markdown file carrying both the slides and the speaker notes;" >&2
  echo "  see the slides section of $PKG/docbuild.conf.example." >&2
  exit 1
fi
SRC="$PROJECT/$SLIDES_SRC"
DIAGRAMS="$PROJECT/${DIAGRAMS_DIR:-docs/diagrams}"
NAME="${SLIDES_NAME:-slides}"
[[ -n "$OUTDIR" ]] || OUTDIR="$(project_pdf_outdir)"
for t in pandoc xelatex inkscape; do
  command -v "$t" >/dev/null || { echo "build-slides.sh: $t not installed" >&2; exit 1; }
done
mkdir -p "$OUTDIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STAMP="$(date +%Y%m%d)"

# --- what still needs building ---
cache_init "$OUTDIR"
SOURCES=("$SRC")
if [[ -d "$DIAGRAMS" ]]; then
  while IFS= read -r f; do SOURCES+=("$f"); done \
    < <(find "$DIAGRAMS" -maxdepth 1 -name 'D*.svg' | sort)
fi
HASH="$(cache_hash "${SOURCES[@]}")"

VARIANTS=(); (( ONLY_NOTES )) || VARIANTS+=(""); VARIANTS+=("_notes")
TODO=()
for suffix in "${VARIANTS[@]}"; do
  stem="$NAME$suffix"
  if (( ! FORCE )); then
    if have="$(cache_current "$stem.pdf" "$HASH" "$OUTDIR")" \
       || { have="$(cache_adopt "$stem.pdf" "$OUTDIR" "${stem}_[0-9]*.pdf" "${SOURCES[@]}")" \
            && cache_record "$stem.pdf" "$HASH" "$have"; }; then
      printf '  %-46s == %s\n' "$stem" "$have"
      continue
    fi
  fi
  TODO+=("$suffix")
done
(( ${#TODO[@]} )) || exit 0

# --- diagrams: SVG -> PDF, so xelatex can embed them ---
if [[ -d "$DIAGRAMS" ]]; then
  for svg in "$DIAGRAMS"/D*.svg; do
    [[ -e "$svg" ]] || continue
    base="$(basename "$svg" .svg)"; key="${base%%-*}"
    inkscape "$svg" -o "$TMP/$key.pdf" --export-type=pdf 2>/dev/null
  done
fi

# --- preprocess: slide markers -> beamer, diagrams -> their own frames ---
python3 - "$SRC" "$TMP/deck.md" "$TMP" <<'ENDPY'
import re, sys, os
src, dst, tmp = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()

# A deck file may open with its own title and a note to the author; the deck itself starts at the
# first part divider or slide after that.
lines = text.split('\n')
start = next((i for i, ln in enumerate(lines)
              if i > 0 and (ln.startswith('# ') or ln.startswith('## '))), 0)
text = '\n'.join(lines[start:])

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
    if '**Notes**' in body:                        # -> pandoc beamer speaker-note div
        on, notes = body.split('**Notes**', 1)
        body = on.rstrip() + '\n\n::: notes\n' + notes.strip() + '\n:::\n'
    body = re.sub(r'(?m)^---\s*$', '', body)

    out.append(f'## {title}\n{body}\n')

    if diag and diag not in seen and os.path.exists(f'{tmp}/{diag}.pdf'):
        seen.add(diag)
        out.append(f'## {diag} {{.plain}}\n\n\\begin{{center}}\n'
                   f'\\includegraphics[width=\\linewidth,height=0.88\\textheight,keepaspectratio]'
                   f'{{{tmp}/{diag}.pdf}}\n\\end{{center}}\n\n')

open(dst, 'w').write('\n'.join(out))
ENDPY

build () {  # $1 = suffix, $2... = extra pandoc args
  local suffix="$1"; shift
  # -V title fills the title frame but is only a template variable; the PDF's own Title
  # property comes from the title-meta metadata, so set both. The notes variant says so,
  # since otherwise the two decks are indistinguishable in a reader's window list.
  local meta_title="${SLIDES_TITLE:-$NAME}"
  [[ "$suffix" == "_notes" ]] && meta_title="$meta_title (with notes)"
  pandoc "$TMP/deck.md" -t beamer -o "$OUTDIR/${NAME}${suffix}_$STAMP.pdf" \
    --pdf-engine=xelatex --slide-level=2 --include-in-header="$PKG/assets/beamer-header.tex" \
    -V aspectratio=169 -V theme=default -V fontsize=10pt -V classoption=t \
    -V mainfont="DejaVu Sans" -V sansfont="DejaVu Sans" -V monofont="DejaVu Sans Mono" \
    -V title="${SLIDES_TITLE:-$NAME}" -M title-meta="$meta_title" \
    -V subtitle="${SLIDES_SUBTITLE:-}" \
    -V date="${SLIDES_DATE:-$(date +'%B %Y')}" "$@"
  cache_record "$NAME$suffix.pdf" "$HASH" "${NAME}${suffix}_$STAMP.pdf"
  printf '  %-46s -> file://%s\n' "${NAME}${suffix}_$STAMP.pdf" "$OUTDIR/${NAME}${suffix}_$STAMP.pdf"
}

for suffix in "${TODO[@]}"; do
  if [[ "$suffix" == "_notes" ]]; then build "_notes" -V "beameroption:show notes"; else build ""; fi
done

# Remove the dated outputs this build supersedes; --keep-old retains them. See cache_prune.
(( KEEP_OLD )) || cache_prune "$OUTDIR"
