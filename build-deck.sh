#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Benoît Dupont de Dinechin
# SPDX-License-Identifier: Apache-2.0
# build-deck.sh — build a designed deck: one PowerPoint file, and the PDFs exported from it.
#
#   build-deck.sh                -> <name>_YYYYMMDD.pptx, .pdf and _notes_YYYYMMDD.pdf
#   build-deck.sh -o DIR         output directory (default DECK_OUTDIR, else deck/)
#   build-deck.sh --force        rebuild even where the sources are unchanged
#   build-deck.sh --keep-old     keep the dated outputs this build supersedes
#   build-deck.sh --project DIR
#
# Same source as build-slides.sh and build-pptx.sh -- the slide-content Markdown named by
# SLIDES_SRC -- rendered the other way round. The .pptx is the master: lib/deck.py lays out every
# slide with one style kit, sizing each text box from the metrics of the font that will render
# it, and LibreOffice exports the PDF and the speaker-notes PDF from that file. There is one
# rendering, so the PDF and the PowerPoint cannot drift apart, and nothing is left to autofit.
#
# Needs pandoc (to parse), python3 with python-pptx and Pillow (to lay out), LibreOffice (to
# export), and the Carlito font, Calibri's metric clone, so that the measured layout is the one
# LibreOffice draws. See doctor.sh.

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
    --force)    FORCE=1 ;;
    --keep-old) KEEP_OLD=1 ;;
    --project)  shift ;;
    -o)         shift; OUTDIR="$1" ;;
    -h|--help)  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "build-deck.sh: unknown argument $1" >&2; exit 2 ;;
  esac; shift
done

if [[ -z "${SLIDES_SRC:-}" ]]; then
  echo "build-deck.sh: this project has no slide deck — docbuild.conf sets no SLIDES_SRC." >&2
  exit 1
fi
SRC="$PROJECT/$SLIDES_SRC"
DIAGRAMS="$PROJECT/${DIAGRAMS_DIR:-docs/diagrams}"
NAME="${SLIDES_NAME:-slides}"
if [[ -z "$OUTDIR" ]]; then
  OUTDIR="${DECK_OUTDIR:-deck}"
  [[ "$OUTDIR" == /* ]] || OUTDIR="$PROJECT/$OUTDIR"
fi
command -v pandoc >/dev/null || { echo "build-deck.sh: pandoc not installed" >&2; exit 1; }
python3 -P -c 'import pptx, PIL' 2>/dev/null \
  || { echo "build-deck.sh: python-pptx not installed (pip install python-pptx)" >&2; exit 1; }
SOFFICE="$(command -v soffice || command -v libreoffice || true)"
[[ -n "$SOFFICE" ]] || { echo "build-deck.sh: LibreOffice (soffice) not installed" >&2; exit 1; }

mkdir -p "$OUTDIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STAMP="$(date +%Y%m%d)"

cache_init "$OUTDIR"
SOURCES=("$SRC")
if [[ -d "$DIAGRAMS" ]]; then
  while IFS= read -r f; do SOURCES+=("$f"); done \
    < <(find "$DIAGRAMS" -maxdepth 1 -name '[DF][0-9]*.svg' | sort)
fi
HASH="$(cache_hash "${SOURCES[@]}")"
# The three outputs are made together, so the .pptx entry stands for all of them.
if (( ! FORCE )) && have="$(cache_current "$NAME.pptx" "$HASH" "$OUTDIR")" \
   && [[ -e "$OUTDIR/${have%.pptx}.pdf" ]]; then
  printf '  %-46s == %s\n' "$NAME" "$have"
  exit 0
fi

PPTX="${NAME}_$STAMP.pptx"
DECK_TITLE="${SLIDES_TITLE:-$NAME}" DECK_SUBTITLE="${SLIDES_SUBTITLE:-}" \
DECK_AUTHOR="${SLIDES_AUTHOR:-}" DECK_DATE="${SLIDES_DATE:-$(date +'%B %Y')}" \
  python3 "$PKG/lib/deck.py" "$SRC" "$TMP/$PPTX" "$DIAGRAMS"

# LibreOffice gets a profile of its own: a desktop session holding the default profile would
# otherwise swallow the conversion request and exit 0 with nothing written.
export_pdf () {  # $1 = filter spec, $2 = output name
  local dir="$TMP/out$RANDOM"
  mkdir -p "$dir"
  "$SOFFICE" -env:UserInstallation="file://$TMP/profile" --headless \
    --convert-to "$1" --outdir "$dir" "$TMP/$PPTX" >"$TMP/soffice.log" 2>&1 || true
  if [[ ! -s "$dir/${PPTX%.pptx}.pdf" ]]; then
    echo "build-deck.sh: LibreOffice export failed:" >&2; sed 's/^/  /' "$TMP/soffice.log" >&2
    exit 1
  fi
  mv "$dir/${PPTX%.pptx}.pdf" "$OUTDIR/$2"
}
export_pdf pdf "${NAME}_$STAMP.pdf"
export_pdf 'pdf:impress_pdf_Export:{"ExportNotesPages":{"type":"boolean","value":"true"},"ExportOnlyNotesPages":{"type":"boolean","value":"true"}}' \
  "${NAME}_notes_$STAMP.pdf"
mv "$TMP/$PPTX" "$OUTDIR/$PPTX"

cache_record "$NAME.pptx" "$HASH" "$PPTX" "$SLIDES_SRC"
cache_record "$NAME.pdf" "$HASH" "${NAME}_$STAMP.pdf" "$SLIDES_SRC"
cache_record "${NAME}_notes.pdf" "$HASH" "${NAME}_notes_$STAMP.pdf" "$SLIDES_SRC"
for f in "$PPTX" "${NAME}_$STAMP.pdf" "${NAME}_notes_$STAMP.pdf"; do
  printf '  %-46s -> file://%s\n' "$f" "$OUTDIR/$f"
done

(( KEEP_OLD )) || cache_prune "$OUTDIR"
