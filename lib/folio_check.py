"""Report text that has strayed into a page's bottom-margin band.

`longtable` cannot break a row across a page. A row taller than the remaining space is not split;
it runs on past the text block and over the folio, and LaTeX says nothing about it — the document
compiles cleanly and the overrun is found by reading the PDF, or not at all. The fix is to split
the cell by hand, but first you have to know which pages are wrong.

So: extract every text box's position and report pages with text inside the band between the
bottom of the text block and the bottom of the paper. The band is passed in because it depends on
the page geometry, and the caller reads it from the project's docbuild.conf.

    python3 folio_check.py LO HI file.pdf [file.pdf ...]

Prints one line per file that has overrun pages, and exits 1 if any file does.
"""

import re
import subprocess
import sys


def overrun_pages(pdf, lo, hi):
    """Page numbers (1-based) carrying text whose bottom edge falls inside the band."""
    proc = subprocess.run(["pdftotext", "-bbox", "-q", pdf, "-"],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"pdftotext failed on {pdf}")
    pages = re.split(r"<page ", proc.stdout)[1:]
    return [n for n, page in enumerate(pages, 1)
            if any(lo < y < hi for y in (float(m) for m in re.findall(r'yMax="([\d.]+)"', page)))]


def main(argv):
    lo, hi = float(argv[1]), float(argv[2])
    found = False
    for pdf in argv[3:]:
        pages = overrun_pages(pdf, lo, hi)
        if pages:
            found = True
            name = pdf.rsplit("/", 1)[-1]
            print(f"    {name}: page{'s' if len(pages) > 1 else ''} "
                  f"{', '.join(str(p) for p in pages)}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
