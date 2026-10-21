#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Benoît Dupont de Dinechin
# SPDX-License-Identifier: Apache-2.0
# build-diagrams.sh — render Graphviz diagram sources to the SVG the other builders consume.
#
#   build-diagrams.sh              render every .dot whose .svg is older or missing
#   build-diagrams.sh --check      render nothing; fail if any .svg is stale — for CI
#   build-diagrams.sh --force      re-render everything
#   build-diagrams.sh --project DIR
#
# Source and output live side by side in DIAGRAMS_DIR: D1-cluster.dot renders to D1-cluster.svg.
# Both are committed. The source is authoritative and the SVG is a build product, but the SVG is
# committed anyway because four consumers want a rendered figure and only one of them can run
# Graphviz: the beamer deck embeds it as vector art, build-pptx.sh redraws it as native
# PowerPoint shapes, a Markdown PDF includes it, and GitHub displays it in a README. --check is
# what keeps a committed SVG honest, exactly as it does for a generated address map.
#
# Why Graphviz and not a diagram editor: see the "Diagrams" section of README.md.
#
# The output is validated against the SVG subset lib/svg2pptx.py accepts, because the failure it
# prevents is remote from its cause. Default Graphviz nodes are <ellipse>, which that converter
# rejects -- and it would reject it during a PowerPoint build, days after the diagram looked
# right everywhere else. So an unsupported element fails here instead, with the fix named.
set -euo pipefail
PKG="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$PKG/lib/project.sh"

PROJECT_DIR="$PWD"
args=("$@"); for i in "${!args[@]}"; do
  [[ "${args[$i]}" == "--project" ]] && PROJECT_DIR="${args[$((i+1))]}"
done
project_load "$PROJECT_DIR"

CHECK=0; FORCE=0
while (( $# )); do
  case "$1" in
    --check)   CHECK=1 ;;
    --force)   FORCE=1 ;;
    --project) shift ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "build-diagrams.sh: unexpected argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -n "${DIAGRAMS_DIR:-}" ]] || { echo "build-diagrams.sh: docbuild.conf sets no DIAGRAMS_DIR" >&2; exit 1; }
DIR="$DIAGRAMS_DIR"; [[ "$DIR" == /* ]] || DIR="$PROJECT/$DIR"
[[ -d "$DIR" ]] || { echo "build-diagrams.sh: no such directory: $DIR" >&2; exit 1; }
command -v dot >/dev/null || { echo "build-diagrams.sh: graphviz (dot) is not installed" >&2; exit 1; }

shopt -s nullglob
SRCS=("$DIR"/*.dot)
(( ${#SRCS[@]} )) || { echo "build-diagrams.sh: no .dot sources in $DIR"; exit 0; }

# Keep this list in step with lib/svg2pptx.py's element walk.
SUBSET='g rect line polygon path text title desc defs metadata style svg'

validate() {  # SVG
  python3 - "$1" "$SUBSET" <<'PY'
import sys, xml.etree.ElementTree as ET
svg, ok = sys.argv[1], set(sys.argv[2].split())
bad = set()
def walk(n):
    for ch in n:
        t = ch.tag.split('}')[-1]
        if t in ok: walk(ch)
        else: bad.add(t)
walk(ET.parse(svg).getroot())
if bad:
    print(", ".join(sorted(bad)))
    sys.exit(1)
PY
}

stale=(); built=0
for src in "${SRCS[@]}"; do
  out="${src%.dot}.svg"; rel="${src#$PROJECT/}"
  if (( ! FORCE )) && [[ -f "$out" && "$out" -nt "$src" ]]; then
    printf '  up to date  %s\n' "$(basename "$out")"
    continue
  fi
  if (( CHECK )); then
    stale+=("$(basename "$out")")
    printf '  STALE       %s\n' "$(basename "$out")"
    continue
  fi
  dot -Tsvg "$src" -o "$out"
  if ! unsupported="$(validate "$out")"; then
    rm -f "$out"
    echo >&2
    echo "build-diagrams.sh: $rel renders SVG that lib/svg2pptx.py cannot convert:" >&2
    echo "  unsupported element(s): $unsupported" >&2
    echo "  Graphviz defaults to <ellipse> nodes. Set 'node [shape=box]' in the digraph," >&2
    echo "  or extend lib/svg2pptx.py to cover the element." >&2
    exit 1
  fi
  printf '  rendered    %s\n' "$(basename "$out")"
  built=$((built + 1))
done

if (( CHECK && ${#stale[@]} )); then
  echo >&2
  echo "${#stale[@]} diagram(s) stale: ${stale[*]}" >&2
  echo "run build-diagrams.sh" >&2
  exit 1
fi
(( built )) && printf '  %d diagram(s) rendered into %s\n' "$built" "${DIR#$PROJECT/}"
exit 0
