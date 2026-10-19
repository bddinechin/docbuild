#!/usr/bin/env bash
# install.sh — put docbuild wrappers into a project.
#
#   ./install.sh /path/to/project [tool ...]
#
# Writes a wrapper for each tool (default: render.sh) and, if the project has no docbuild.conf
# yet, a commented skeleton to fill in. Nothing else is copied: the project holds a wrapper and
# its conf, the package holds the build. Re-running it is safe — an existing docbuild.conf is
# never overwritten.

set -euo pipefail
PKG="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT="${1:?usage: install.sh /path/to/project [tool ...]}"
shift || true
TOOLS=("$@"); (( ${#TOOLS[@]} )) || TOOLS=(render.sh)

[[ -d "$PROJECT" ]] || { echo "install.sh: no such directory: $PROJECT" >&2; exit 1; }
for tool in "${TOOLS[@]}"; do
  [[ -x "$PKG/$tool" ]] || { echo "install.sh: no such tool: $tool" >&2; exit 1; }
  install -m 755 "$PKG/assets/wrapper.sh" "$PROJECT/$tool"
  echo "  wrapper   $PROJECT/$tool"
done

if [[ -e "$PROJECT/docbuild.conf" ]]; then
  echo "  kept      $PROJECT/docbuild.conf"
else
  cp "$PKG/docbuild.conf.example" "$PROJECT/docbuild.conf"
  echo "  skeleton  $PROJECT/docbuild.conf   <- edit this"
fi
