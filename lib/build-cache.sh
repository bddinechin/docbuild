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
#   cache_prune DIR                     delete dated outputs the manifest has superseded
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
#
# Dated filenames and pruning are two halves of one idea. Keeping the date means a reader can
# tell which version they were sent; it does not mean keeping every version forever. Once the
# manifest records a newer build for a document, the older dated file is not history, it is a
# trap: it sits in the same directory, sorts next to the current one, and is exactly as easy to
# attach to an email. So a build removes what it supersedes, and `--keep-old` opts out.

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

cache_prune() {  # DIR
  # Each manifest entry names the one current output for its key. Any other dated file with the
  # same stem and extension was current once and has been superseded. A stem with no manifest
  # entry is left alone: without an entry there is no basis for calling any of its files stale,
  # and guessing from mtime is how you delete the wrong one.
  local dir="$1" key hash cur stem ext f removed=0
  [[ -n "$CACHE_FILE" && -f "$CACHE_FILE" ]] || return 0
  while IFS=$'\t' read -r key hash cur; do
    [[ -n "$key" && -n "$cur" && -f "$dir/$cur" ]] || continue
    stem="${key%.*}"; ext="${key##*.}"
    for f in "$dir/$stem"_[0-9]*."$ext"; do
      [[ -f "$f" && "$(basename "$f")" != "$cur" ]] || continue
      rm -f -- "$f" && printf '  superseded by %s: removed %s\n' "$cur" "$(basename "$f")"
      removed=$((removed + 1))
    done
  done < "$CACHE_FILE"
  (( removed )) && printf '  %d superseded file(s) removed -- --keep-old retains them next time\n' "$removed"
  return 0
}
