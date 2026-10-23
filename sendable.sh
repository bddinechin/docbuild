#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Benoît Dupont de Dinechin
# SPDX-License-Identifier: Apache-2.0
# sendable.sh — publish the current build of a document under a name fit to send someone.
#
#   sendable.sh              copy each mapped document, remove the copies it supersedes
#   sendable.sh --list       show what would happen, change nothing
#   sendable.sh --keep-old   leave superseded copies in place
#   sendable.sh --project DIR
#
# Build outputs are named for the tools: docs_cluster-plan_20261023.pdf says which Markdown file
# it came from, which is right inside the project and wrong in an attachment. The conf maps each
# build output to a name a recipient can read, and this copies it out:
#
#   SENDABLE_DIR="$HOME"
#   sendable_map() {
#     echo "docs_cluster-plan.pdf  myproject-cluster-plan"
#   }
#
# The mapping is written out rather than derived because the useful name is rarely a transform of
# the file name -- docs_work-computer-todo becomes work-todo, and no rule produces that.
#
# The date in the published name is the date of the *build*, taken from the manifest, not today.
# A document that has not changed keeps the date it last changed, which is the same principle the
# dated build names rest on: the stamp says when the content changed, not when someone ran a tool.
#
# Superseded copies are removed for the reason the build directory prunes its own: an older PDF
# beside the current one sorts next to it and is exactly as easy to attach by mistake. The
# destination is usually a home directory rather than a build directory, so the glob used to find
# them is deliberately exact -- <name>-YYYY-MM-DD.pdf and nothing else.
set -euo pipefail
PKG="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$PKG/lib/project.sh"
source "$PKG/lib/build-cache.sh"

PROJECT_DIR="$PWD"
args=("$@"); for i in "${!args[@]}"; do
  [[ "${args[$i]}" == "--project" ]] && PROJECT_DIR="${args[$((i+1))]}"
done
project_load "$PROJECT_DIR"

LIST=0; KEEP_OLD=0
while (( $# )); do
  case "$1" in
    --list)     LIST=1 ;;
    --keep-old) KEEP_OLD=1 ;;
    --project)  shift ;;
    -h|--help)  sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "sendable.sh: unexpected argument: $1" >&2; exit 2 ;;
  esac
  shift
done

declare -F sendable_map >/dev/null || {
  echo "sendable.sh: $PROJECT/docbuild.conf declares no sendable_map" >&2; exit 1; }

DEST="${SENDABLE_DIR:-$HOME}"
[[ "$DEST" == /* ]] || DEST="$PROJECT/$DEST"
[[ -d "$DEST" ]] || { echo "sendable.sh: no such directory: $DEST" >&2; exit 1; }

SRC="$(project_pdf_outdir)"
cache_init "$SRC"

copied=0; removed=0; missing=0
while read -r key name; do
  [[ -n "$key" && -n "$name" ]] || continue

  # The manifest is authoritative about which dated file is the current build of a document.
  build="$(awk -F'\t' -v s="$key" '$1 == s { print $3; exit }' "$SRC/.build-manifest")"
  if [[ -z "$build" || ! -f "$SRC/$build" ]]; then
    printf '  MISSING   %-30s no current build — run render.sh --pdf\n' "$key" >&2
    missing=$((missing + 1)); continue
  fi

  # docs_cluster-plan_20261023.pdf -> 2026-10-23
  stamp="${build##*_}"; stamp="${stamp%.pdf}"
  if [[ ! "$stamp" =~ ^[0-9]{8}$ ]]; then
    printf '  SKIP      %-30s cannot read a date from %s\n' "$key" "$build" >&2
    missing=$((missing + 1)); continue
  fi
  dated="$name-${stamp:0:4}-${stamp:4:2}-${stamp:6:2}.pdf"

  if (( LIST )); then
    printf '  would copy  %s  ->  %s\n' "$build" "$DEST/$dated"
  else
    cp -- "$SRC/$build" "$DEST/$dated"
    printf '  %-46s %s\n' "$dated" "$(cd "$DEST" && du -h "$dated" | cut -f1)"
    copied=$((copied + 1))
  fi

  (( KEEP_OLD )) && continue
  for old in "$DEST/$name"-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].pdf; do
    [[ -f "$old" && "$(basename "$old")" != "$dated" ]] || continue
    if (( LIST )); then
      printf '  would remove  %s\n' "$(basename "$old")"
    else
      rm -f -- "$old"
      printf '    superseded, removed %s\n' "$(basename "$old")"
      removed=$((removed + 1))
    fi
  done
done < <(sendable_map)

(( LIST )) && exit 0
printf '  %d copied, %d superseded removed, into %s\n' "$copied" "$removed" "$DEST"
(( missing )) && exit 1
exit 0
