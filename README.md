# docbuild

Markdown to dated PDF, HTML preview, beamer deck and editable PowerPoint — shared between
projects that keep their documents as Markdown in the tree.

It exists because the same `render.sh` had been copied into three project directories and had
started to drift: the engine was identical, only the document list and the output directory
differed. Here the engine is the package and the difference is a per-project `docbuild.conf`.

Everything runs locally: pandoc, xelatex, inkscape, python-pptx. **No network calls** — some of
the projects using this hold sensitive or unpublished material, and rendering must never be the
thing that sends a document somewhere.

## Using it in a project

```sh
git clone <this repo> ~/docbuild
~/docbuild/install.sh /path/to/project render.sh
$EDITOR /path/to/project/docbuild.conf
```

`install.sh` writes a wrapper into the project and, if there is none, a `docbuild.conf`
skeleton. From then on the project is driven from inside itself:

```sh
cd /path/to/project
./render.sh                 # HTML preview of the default documents
./render.sh --all --pdf     # a named fileset, as dated PDFs
```

Add `build-slides.sh` and `build-pptx.sh` to the `install.sh` line for a project that has a
slide deck.

The wrapper finds the package in `$DOCBUILD`, then `.docbuild/` in the project, then
`~/docbuild` — so the package can be cloned once per machine, or vendored per project, without
the project's own scripts changing.

## What a project declares

`docbuild.conf` is sourced shell, but should stay declarative — see `docbuild.conf.example`.
It names where output goes and which documents matter:

```sh
DOC_ABOUT="Example project — design notes"
PDF_OUTDIR="Output/pdf"

fileset_default() { echo "Output/Design_Note.md"; }
fileset_all()     { find "$PROJECT/Output" -maxdepth 1 -name '*.md' | sort; }
```

Every `fileset_<name>` function becomes a `--<name>` flag, so the second one above is
`./render.sh --all`. A project that keeps its PDFs out of the tree sets `PDF_OUTDIR=""`.

## Titles

A document's title reaches the PDF properties and the HTML `<title>`. By default each document
takes its **own first `# heading`**, falling back to its path only if it has none — so a document
that names itself needs no configuration. `DOC_TITLE` overrides it where a project wants something
else, and applies to every document a single invocation renders, which suits a single-document
project.

The title is passed to pandoc as `title-meta` and `pagetitle` rather than as `title`. Those reach
the document properties without pandoc also rendering a title block above the document's own
heading, which is what produced a stray path on the first page of every PDF before. Note the title
is not part of the content hash, so use `--force` after changing `DOC_TITLE`.

## Dated filenames, and why they do not multiply

Output carries the build date — `Output_Design_Note_20260903.pdf` — so successive
builds sit side by side and the reader can tell which version they were sent.

Left alone, that turns every rebuild into a new file whose date means "this is when the script
last ran". So an output is rebuilt **only when its sources have changed**, tracked by SHA-256 in
a `.build-manifest` beside the output. Rebuild everything nonetheless with `--force` — which is
what to use after editing the LaTeX preamble or upgrading pandoc, since the hash deliberately
covers the sources and not the toolchain.

A deck's sources include every diagram, because a diagram edit changes the deck without touching
any Markdown.

The first run against a directory that already holds output has no manifest to consult. Rather
than rebuild everything once to learn what is current, it accepts an existing dated file whose
mtime is newer than every source — the claim "this was built from these sources". That heuristic
applies only where there is no manifest entry; after that the comparison is by content.

A build also **removes the dated files it supersedes**. The date is there so a reader can tell
which version they were sent, which argues for naming the file, not for keeping every one: an
older PDF beside the current one sorts right next to it and is exactly as easy to attach to an
email. `--keep-old` retains them.

Pruning is driven by the manifest and is deliberately narrow. A stem with no manifest entry is
left alone — without an entry there is nothing to call those files superseded *against*, and
guessing from mtime is how you delete the wrong one — and an entry whose recorded file has gone
missing prunes nothing. Keys carry the extension, so a `.pptx` entry never prunes a `.pdf` of
the same name. It runs after the whole fileset rather than per document, so a run that rebuilt
nothing still clears what earlier runs left, including for documents not named on the command
line.

## Slides

`build-slides.sh` and `build-pptx.sh` read one Markdown file that carries both the deck and what
to say over it:

```markdown
# Part 2 — Architecture

## 6 — Cluster    ·    D1

**On slide**
- four CVA6 cores behind one coherence unit

**Notes**
Say why four and not eight: it is the width Culsans supports unmodified.
```

`**On slide**` becomes the frame, `**Notes**` becomes the speaker notes, and the `· D1` suffix
inserts `docs/diagrams/D1-*.svg` as a full-bleed frame after the slide that first refers to it.

The two builders differ in what they do with the diagrams. The beamer PDF embeds them as vector
art. The PowerPoint build **redraws them as native shapes** — rect, line, polygon and text each
become a real PowerPoint object — so a house template can restyle them. `lib/svg2pptx.py` covers
the SVG subset the diagrams use and raises on anything else, so an unsupported construct fails
the build rather than silently vanishing from the slide.

## LaTeX

Some projects keep LaTeX as the master rather than Markdown — a directory of documents sharing
one style file. `build-latex.sh` builds those on the same terms:

```sh
./build-latex.sh                 # every document in LATEX_DIR
./build-latex.sh Report_Alpha.tex  # just one
```

Every `.tex` declaring a `\documentclass` is a document; the rest are includes, so editing the
shared style rebuilds all of them and editing one document rebuilds only that one. The engine
runs three times by default, since `longtable` column widths need a third pass to settle, and the
intermediate files go to a scratch directory so the tree keeps only sources and PDFs.

Output follows the source name — `Report_Alpha.tex` gives `Report_Alpha.pdf` — rather than taking a
date stamp, because a LaTeX deliverable is usually cited by a name that has to stay put.
`LATEX_STAMP=date` opts into the dated names instead.

With `LATEX_FOLIO_CHECK` set, each built PDF is checked for text that has run into the bottom
margin. That is the silent failure of a `longtable` row too tall for the space left on the page:
it is not split, it runs over the folio, and LaTeX reports nothing. The check reports the file
and the page numbers; `--strict` makes it fail the build.

## Layout

| | |
|---|---|
| `render.sh` | documents: HTML preview, dated PDF |
| `build-slides.sh` | beamer deck, two variants (with and without notes) |
| `build-pptx.sh` | the same deck as editable `.pptx` |
| `build-latex.sh` | LaTeX documents sharing a style file |
| `install.sh` | put wrappers into a project |
| `lib/project.sh` | find and load `docbuild.conf` |
| `lib/build-cache.sh` | the content-hash manifest |
| `lib/svg2pptx.py` | SVG to native PowerPoint shapes |
| `lib/folio_check.py` | find text that has overrun into the bottom margin |
| `assets/` | LaTeX preamble, HTML style, table-width filter, wrapper template |

## Licence

Copyright 2026 Benoît Dupont de Dinechin

Licensed under the Apache License, Version 2.0 (`Apache-2.0`) — see [LICENSE](LICENSE).
You may not use these files except in compliance with the License. A copy is at
<https://www.apache.org/licenses/LICENSE-2.0>.
