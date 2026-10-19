# SPDX-FileCopyrightText: 2026 Benoît Dupont de Dinechin
# SPDX-License-Identifier: Apache-2.0
# build-cache.sh — skip a rebuild whose sources have not changed. Source this, do not run it.
#
# Output filenames carry the build date, so an unconditional rebuild drops a second copy of an
# identical document into docs/pdf under today's stamp. That makes the directory grow with dates
# that mean nothing: "this is when the script last ran", not "this is when the document changed".
# The manifest below keys each output on the SHA-256 of the sources it was built from, so a
# rebuild produces a new dated file only when the content actually differs.
#
#   cache_init DIR                      manifest lives in DIR/.build-manifest
#   cache_hash SRC...                   SHA-256 over the concatenated sources
#   cache_current KEY HASH DIR          prints the existing filename and returns 0 if up to date
#   cache_adopt KEY DIR GLOB SRC...     first run: accept an existing output as current
#   cache_record KEY HASH FILENAME      remember what was built
#
# The key is the output's stem plus its extension — `docs_wbs.pdf`, `Deck.pptx`. The extension
# matters: two tools building the same deck into one directory, one as PDF and one as PowerPoint,
# would otherwise share a key and each read the other's entry as its own.
#
# cache_adopt exists because the manifest starts empty against a directory that already holds
# output. Rather than rebuild everything once to learn what is current, it accepts an existing
# file whose mtime is newer than every source — which is exactly the claim "it was built from
# these sources". That heuristic is used only when there is no manifest entry; afterwards the
# comparison is by content.
#
# The hash covers the sources, not the build scripts or the toolchain, so editing a template or
# upgrading pandoc will not by itself produce a new dated file. Pass --force in that case.

CACHE_FILE=""

cache_init() {
  CACHE_FILE="$1/.build-manifest"
  [[ -f "$CACHE_FILE" ]] || : > "$CACHE_FILE"
}

cache_hash() { cat "$@" | sha256sum | cut -d' ' -f1; }

cache_current() {  # KEY HASH DIR
  local line hash file
  line="$(awk -F'\t' -v s="$1" '$1 == s { print $2 "\t" $3; exit }' "$CACHE_FILE")"
  [[ -n "$line" ]] || return 1
  hash="${line%%$'\t'*}"; file="${line#*$'\t'}"
  [[ "$hash" == "$2" && -f "$3/$file" ]] || return 1
  printf '%s\n' "$file"
}

cache_adopt() {  # KEY DIR GLOB SRC...
  local key="$1" dir="$2" glob="$3" newest src; shift 3
  awk -F'\t' -v s="$key" '$1 == s { found = 1 } END { exit !found }' "$CACHE_FILE" && return 1
  newest="$(find "$dir" -maxdepth 1 -name "$glob" | sort | tail -1)"
  [[ -n "$newest" ]] || return 1
  for src in "$@"; do if [[ "$src" -nt "$newest" ]]; then return 1; fi; done
  basename "$newest"
}

cache_record() {  # KEY HASH FILENAME
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v s="$1" '$1 != s' "$CACHE_FILE" > "$tmp"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$tmp"
  sort -o "$CACHE_FILE" "$tmp"
  rm -f "$tmp"
}
