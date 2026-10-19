#!/usr/bin/env bash
# Thin wrapper — the build itself lives in the docbuild package, which is shared between
# projects. This file only finds the package and hands it this project. What is specific to
# this project is in docbuild.conf beside it.
#
# The package is looked for in $DOCBUILD, then .docbuild/ here, then ~/docbuild.
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(basename "${BASH_SOURCE[0]}")"
for candidate in "${DOCBUILD:-}" "$PROJECT/.docbuild" "$HOME/docbuild"; do
  [[ -n "$candidate" && -x "$candidate/$TOOL" ]] && exec "$candidate/$TOOL" --project "$PROJECT" "$@"
done
echo "$TOOL: docbuild package not found — clone it and set DOCBUILD=/path/to/docbuild" >&2
exit 1
