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
#   cache_record KEY HASH FILENAME [SRCREL...]   remember what was built, and from what
#   cache_prune DIR                     delete dated outputs the manifest has superseded
#   cache_orphans DIR ROOT KNOWN...     classify entries no longer claimed by a caller
#   cache_forget KEY                    drop an entry
#
# A fourth field records the sources an entry was built from, relative to the project root and
# comma-joined. It exists so that an output whose source was renamed or deleted can be told apart
# from an output another tool in the same directory owns -- build-slides.sh writes deck PDFs into
# the same directory and the same manifest, and they belong to no fileset. Without recorded
# provenance the two are indistinguishable, and the safe reading of "not in any fileset" is
# "somebody else's", which is why orphans accumulated unnoticed. Entries written before this
# field existed, or by a caller that passes no sources, keep three fields and are reported as
# provenance-unknown rather than guessed at.
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

cache_record() {  # KEY HASH FILENAME [SRCREL...]
  local key="$1" hash="$2" file="$3"; shift 3
  local srcs="" s tmp
  for s in "$@"; do srcs="${srcs:+$srcs,}$s"; done
  tmp="$(mktemp)"
  awk -F'\t' -v s="$key" '$1 != s' "$CACHE_FILE" > "$tmp"
  printf '%s\t%s\t%s\t%s\n' "$key" "$hash" "$file" "$srcs" >> "$tmp"
  sort -o "$CACHE_FILE" "$tmp"
  rm -f "$tmp"
}

# The sources an entry was built from, or empty when it predates the field. Callers use this to
# decide whether an entry can be reasoned about, never to rebuild from.
cache_sources() {  # KEY
  [[ -n "$CACHE_FILE" && -f "$CACHE_FILE" ]] || return 1
  awk -F'\t' -v s="$1" '$1 == s { print $4; exit }' "$CACHE_FILE"
}

cache_forget() {  # KEY
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v s="$1" '$1 != s' "$CACHE_FILE" > "$tmp"
  sort -o "$CACHE_FILE" "$tmp"
  rm -f "$tmp"
}

cache_prune() {  # DIR
  # Each manifest entry names the one current output for its key. Any other dated file with the
  # same stem and extension was current once and has been superseded. A stem with no manifest
  # entry is left alone: without an entry there is no basis for calling any of its files stale,
  # and guessing from mtime is how you delete the wrong one.
  local dir="$1" key hash cur srcs stem ext f removed=0
  [[ -n "$CACHE_FILE" && -f "$CACHE_FILE" ]] || return 0
  while IFS=$'\t' read -r key hash cur srcs; do
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

# An entry is an orphan when the caller no longer claims its key and every source it was built
# from is gone: a document renamed or deleted leaves both its dated output and its manifest entry
# behind, and cache_prune cannot see either, because it only ever reasons about keys it still
# knows. Classification only -- what to do about one is the caller's policy, and deleting on a
# guess is how the wrong file goes.
#
# Prints one tab-separated line per unclaimed entry:
#   orphan <key> <file> <sources>     every recorded source is missing
#   unknown <key> <file>              no recorded provenance, so no basis for a verdict
cache_orphans() {  # DIR ROOT KNOWN...
  local dir="$1" root="$2"; shift 2
  [[ -n "$CACHE_FILE" && -f "$CACHE_FILE" ]] || return 0
  local -A known=()
  local k; for k in "$@"; do known["$k"]=1; done
  local key hash cur srcs s present
  while IFS=$'\t' read -r key hash cur srcs; do
    [[ -n "$key" ]] || continue
    [[ -z "${known[$key]:-}" ]] || continue
    if [[ -z "$srcs" ]]; then
      printf 'unknown\t%s\t%s\n' "$key" "$cur"
      continue
    fi
    present=0
    while IFS= read -r s; do
      [[ -n "$s" ]] || continue
      [[ "$s" == /* ]] || s="$root/$s"
      [[ -e "$s" ]] && { present=1; break; }
      # printf with the newline: without it `read` hits EOF on the last field and the loop
      # body never runs for it, so a single-source entry reads as having no surviving source.
    done < <(printf '%s\n' "$srcs" | tr ',' '\n')
    (( present )) || printf 'orphan\t%s\t%s\t%s\n' "$key" "$cur" "$srcs"
  done < "$CACHE_FILE"
  return 0
}
