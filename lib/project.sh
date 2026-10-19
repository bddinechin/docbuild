# project.sh — locate and load a project's docbuild.conf. Source this, do not run it.
#
# A project describes itself in a single file, docbuild.conf at its root. Everything the tools
# need that varies between projects lives there: which documents are the deliverables, where the
# output goes, and how the project talks about itself in --help. Nothing else is project-specific,
# which is why the tools themselves can be shared.
#
# The conf is sourced, so it is shell — but it should stay declarative: a few variables and a few
# `fileset_*` functions. It is read before any tool does work, and it must not produce output.

PROJECT=""          # absolute path to the project root
DOC_ABOUT=""        # one line, shown in --help
PDF_OUTDIR=""       # relative to the project, or absolute; empty means "alongside the previews"
HTML_OUTDIR=""      # empty means $TMPDIR/<project>-preview
PDF_HEADER=""       # LaTeX preamble; empty means the packaged one
HTML_STYLE=""       # <style> block; empty means the packaged one
PDF_OPTS=()         # extra pandoc arguments for PDF output

project_load() {  # PROJECT_DIR
  PROJECT="$(cd "$1" && pwd)"
  local conf="$PROJECT/docbuild.conf"
  [[ -f "$conf" ]] || { echo "docbuild: no docbuild.conf in $PROJECT" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$conf"
  : "${DOC_NAME:=$(basename "$PROJECT")}"
}

# Filesets are declared by the conf as `fileset_<name>`, and each one becomes a `--<name>` flag.
# `fileset_default` supplies the documents to render when none are named on the command line.
project_filesets() { declare -F | sed -n 's/^declare -f fileset_//p' | sort; }

project_has_fileset() { declare -F "fileset_$1" >/dev/null; }

# Emit a fileset's files as absolute paths. A conf may list them relative to the project root,
# which is what makes a conf readable.
project_fileset() {  # NAME
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$f" == /* ]] || f="$PROJECT/$f"
    printf '%s\n' "$f"
  done < <("fileset_$1")
}

# Where output lands. HTML previews are transient and stay out of the project tree; PDFs go where
# the conf says, which for a project whose PDF is a deliverable is inside the tree.
project_html_outdir() {
  printf '%s\n' "${HTML_OUTDIR:-${TMPDIR:-/tmp}/${DOC_NAME}-preview}"
}

project_pdf_outdir() {
  local d="$PDF_OUTDIR"
  [[ -n "$d" ]] || { project_html_outdir; return; }
  [[ "$d" == /* ]] || d="$PROJECT/$d"
  printf '%s\n' "$d"
}
