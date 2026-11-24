# SPDX-FileCopyrightText: 2026 Benoît Dupont de Dinechin
# SPDX-License-Identifier: Apache-2.0
"""deck.py — lay out a slide-content Markdown file as a designed PowerPoint deck.

    deck.py SRC.md OUT.pptx DIAGRAMS_DIR

The Markdown follows the deck conventions of build-slides.sh (`# Part`, `## N — Title · F3`,
`**On slide**` / `**Notes**`). pandoc parses it -- so inline syntax, smart quotes and tables mean
exactly what they mean in every other docbuild output -- and this module does the layout itself,
with one style kit, instead of handing the slide to pandoc's pptx writer.

What makes the result faithful is that nothing is left to autofit. Every text box is sized here,
from the metrics of the font that will render it (Calibri, measured through its metric clone
Carlito; Courier New through Liberation Mono), with exact line spacing and fixed paragraph spacing.
PowerPoint and LibreOffice then have no layout decision left to disagree about, so the PDF that
LibreOffice exports from the .pptx is the slide PowerPoint shows.

Environment: DECK_TITLE, DECK_SUBTITLE, DECK_AUTHOR, DECK_DATE for the title slide and footer.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
from functools import lru_cache

from lxml import etree
from PIL import ImageFont
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, MSO_AUTO_SIZE, PP_ALIGN
from pptx.oxml.ns import qn
from pptx.util import Emu, Inches, Pt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import figtitle  # noqa: E402
import svg2pptx  # noqa: E402

# ---------------------------------------------------------------------------------------------
# Style kit. Everything visual is decided here; the slide functions below only place things.

FONT = "Calibri"
MONO = "Courier New"
ACCENT = RGBColor(0x1F, 0x4E, 0x79)      # one colour, used for structure only
ACCENT_PALE = RGBColor(0xDD, 0xE7, 0xF1)
INK = RGBColor(0x1A, 0x1A, 0x1A)         # titles, bold runs
BODY = RGBColor(0x33, 0x33, 0x33)        # running text
MUTED = RGBColor(0x80, 0x80, 0x80)       # kicker, footer, captions
RULE = RGBColor(0xC8, 0xC8, 0xC8)
CODE_BG = RGBColor(0xF3, 0xF4, 0xF6)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)

SLIDE_W, SLIDE_H = Inches(13.333), Inches(7.5)
MX = Inches(0.6)                          # side margin
CONTENT_W = SLIDE_W - 2 * MX
KICKER_Y = Inches(0.38)
TITLE_Y = Inches(0.62)
BODY_BOTTOM = Inches(6.85)
FOOTER_Y = Inches(7.02)

BODY_MAX, BODY_MIN = 24, 11               # body text size range, points
LINE = 1.17                               # line pitch as a multiple of the size
BULLET_GAP = 0.45                         # space after a bullet, as a multiple of the size
BLOCK_GAP = Inches(0.22)                  # between a list, a table and a code block
INDENT = [Inches(0.28), Inches(0.62)]     # hanging indent of each bullet level
SAFETY = 0.98                             # measured widths are trusted to this fraction

EMU_PT = 12700

# ---------------------------------------------------------------------------------------------
# Font metrics. Calibri itself is rarely installed on the build machine; Carlito has identical
# advance widths, and it is also what LibreOffice substitutes when it exports the PDF.


def _font_file(spec):
    try:
        return subprocess.run(["fc-match", "-f", "%{file}", spec], capture_output=True,
                              text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


@lru_cache(maxsize=None)
def _face(family, bold, italic):
    style = ":bold" if bold else ""
    style += ":italic" if italic else ""
    path = _font_file(family + style)
    return ImageFont.truetype(path, 1000)


def check_fonts():
    got = os.path.basename(_font_file(FONT))
    if not got.lower().startswith(("carlito", "calibri")):
        print(f"deck.py: warning: {FONT} resolves to {got}; install fonts-crosextra-carlito, "
              "or the PDF will not match PowerPoint", file=sys.stderr)


def text_width(text, size, bold=False, italic=False, mono=False):
    """Advance width of TEXT in EMU at SIZE points."""
    face = _face(MONO if mono else FONT, bold, italic)
    return face.getlength(text) * size / 1000 * EMU_PT


# ---------------------------------------------------------------------------------------------
# Inline content: pandoc's inline AST flattened into runs.


class Run:
    __slots__ = ("text", "bold", "italic", "code", "link", "sup", "sub")

    def __init__(self, text, bold=False, italic=False, code=False, link=None, sup=False,
                 sub=False):
        self.text, self.bold, self.italic, self.code = text, bold, italic, code
        self.link, self.sup, self.sub = link, sup, sub

    def like(self, text):
        return Run(text, self.bold, self.italic, self.code, self.link, self.sup, self.sub)


def runs_of(inlines, bold=False, italic=False, link=None, sup=False, sub=False):
    out = []

    def add(text, **kw):
        out.append(Run(text, kw.get("bold", bold), kw.get("italic", italic), kw.get("code", False),
                       kw.get("link", link), sup, sub))

    for il in inlines:
        t, c = il["t"], il.get("c")
        if t == "Str":
            add(c)
        elif t in ("Space", "SoftBreak"):
            add(" ")
        elif t == "LineBreak":
            add("\n")
        elif t == "Strong":
            out += runs_of(c, True, italic, link, sup, sub)
        elif t == "Emph":
            out += runs_of(c, bold, True, link, sup, sub)
        elif t in ("Underline", "SmallCaps", "Strikeout"):
            out += runs_of(c, bold, italic, link, sup, sub)
        elif t == "Superscript":
            out += runs_of(c, bold, italic, link, True, sub)
        elif t == "Subscript":
            out += runs_of(c, bold, italic, link, sup, True)
        elif t == "Code":
            add(c[1], code=True)
        elif t == "Math":
            add(c[1], italic=True)
        elif t == "Link":
            out += runs_of(c[1], bold, italic, c[2][0], sup, sub)
        elif t == "Quoted":
            q = ("“", "”") if c[0]["t"] == "DoubleQuote" else ("‘", "’")
            add(q[0])
            out += runs_of(c[1], bold, italic, link, sup, sub)
            add(q[1])
        elif t in ("Span", "Cite"):
            out += runs_of(c[1] if t == "Span" else c[1], bold, italic, link, sup, sub)
        elif t == "Image":
            out += runs_of(c[1], bold, italic, link, sup, sub)
        # RawInline, Note: nothing on a slide
    return out


def plain_text(runs):
    return "".join(r.text for r in runs)


# ---------------------------------------------------------------------------------------------
# Measuring: greedy line breaking, the way PowerPoint and LibreOffice both do it.


def _run_size(r, size):
    s = size * (0.92 if r.code else 1.0)
    return s * (0.7 if (r.sup or r.sub) else 1.0)


def count_lines(runs, size, width):
    """Lines RUNS occupy when wrapped at WIDTH (EMU) at SIZE points."""
    width *= SAFETY
    lines, x = 1, 0.0
    # tokens: words with their trailing space, split across run boundaries by style
    for r in runs:
        for part in re.split(r"(\n)", r.text):
            if part == "\n":
                lines, x = lines + 1, 0.0
                continue
            for tok in re.findall(r"\S+\s*|\s+", part):
                word = tok.rstrip()
                w_word = text_width(word, _run_size(r, size), r.bold, r.italic, r.code)
                w_tok = text_width(tok, _run_size(r, size), r.bold, r.italic, r.code)
                if x > 0 and word and x + w_word > width:
                    lines, x = lines + 1, 0.0
                    if not word:
                        continue
                while w_word > width:            # a word longer than the line breaks anywhere
                    lines, w_word, w_tok = lines + 1, w_word - width, w_tok - width
                x += w_tok
    return lines


def natural_width(runs, size):
    return sum(text_width(r.text, _run_size(r, size), r.bold, r.italic, r.code) for r in runs)


def longest_word(runs, size):
    best = 0.0
    for r in runs:
        for word in r.text.split():
            best = max(best, text_width(word, _run_size(r, size), r.bold, r.italic, r.code))
    return best


# ---------------------------------------------------------------------------------------------
# Writing text into a shape with everything explicit.


def _no_autofit(tf, inset=(0, 0, 0, 0)):
    tf.word_wrap = True
    tf.auto_size = MSO_AUTO_SIZE.NONE
    tf.margin_left, tf.margin_top, tf.margin_right, tf.margin_bottom = [Emu(int(v)) for v in inset]


def _para_format(p, size, space_after=0.0, space_before=0.0):
    p.line_spacing = Pt(round(size * LINE, 1))
    p.space_after = Pt(round(space_after, 1))
    p.space_before = Pt(round(space_before, 1))


def _write_runs(p, runs, size, color=BODY, bold_color=INK):
    for r in runs:
        if not r.text:
            continue
        pieces = r.text.split("\n")
        for i, piece in enumerate(pieces):
            if i:
                p.add_line_break()
            if not piece:
                continue
            run = p.add_run()
            run.text = piece
            f = run.font
            f.size = Pt(round(_run_size(r, size) * 2) / 2)
            f.bold = r.bold
            f.italic = r.italic
            f.name = MONO if r.code else FONT
            f.color.rgb = bold_color if r.bold else color
            if r.code:
                f.color.rgb = INK
            if r.link:
                run.hyperlink.address = r.link
                f.color.rgb = ACCENT
            if r.sup or r.sub:
                run._r.get_or_add_rPr().set("baseline", "30000" if r.sup else "-25000")


def _bullet(p, char, color, indent):
    """A hanging bullet in CHAR, coloured, at INDENT (EMU)."""
    ppr = p._p.get_or_add_pPr()
    ppr.set("marL", str(int(indent)))
    ppr.set("indent", str(-int(Inches(0.22))))
    for tag in ("a:buClr", "a:buFont", "a:buChar", "a:buNone"):
        for el in ppr.findall(qn(tag)):
            ppr.remove(el)
    clr = etree.SubElement(ppr, qn("a:buClr"))
    etree.SubElement(clr, qn("a:srgbClr"), val=str(color))
    etree.SubElement(ppr, qn("a:buFont"), typeface=FONT)
    etree.SubElement(ppr, qn("a:buChar"), char=char)


def _no_bullet(p):
    ppr = p._p.get_or_add_pPr()
    ppr.set("marL", "0")
    ppr.set("indent", "0")
    etree.SubElement(ppr, qn("a:buNone"))


def textbox(slide, x, y, w, h, inset=(0, 0, 0, 0), anchor=MSO_ANCHOR.TOP):
    tb = slide.shapes.add_textbox(Emu(int(x)), Emu(int(y)), Emu(int(w)), Emu(int(h)))
    tf = tb.text_frame
    _no_autofit(tf, inset)
    tf.vertical_anchor = anchor
    return tb, tf


def simple_text(slide, text, x, y, w, h, size, color=INK, bold=False, align=PP_ALIGN.LEFT,
                anchor=MSO_ANCHOR.TOP, spacing=None, italic=False):
    tb, tf = textbox(slide, x, y, w, h, anchor=anchor)
    p = tf.paragraphs[0]
    p.alignment = align
    _para_format(p, size)
    _write_runs(p, [Run(text, bold=bold, italic=italic)], size, color, color)
    if spacing:
        for r in p.runs:
            r._r.get_or_add_rPr().set("spc", str(int(spacing * 100)))
    return tb


# ---------------------------------------------------------------------------------------------
# Body blocks. Each knows its height at a given size, and how to draw itself.


class Bullets:
    """A bullet list, flattened to (level, runs) items. Paragraphs are level -1: no bullet."""

    def __init__(self, items):
        self.items = items

    def height(self, size, width):
        h = 0.0
        for level, runs in self.items:
            s = size if level <= 0 else size - 1
            w = width - (INDENT[min(level, 1)] if level >= 0 else 0)
            h += count_lines(runs, s, w) * s * LINE + s * BULLET_GAP
        return h * EMU_PT

    def draw(self, slide, x, y, width, size):
        h = self.height(size, width)
        _, tf = textbox(slide, x, y, width, h + Inches(0.1))
        first = True
        for level, runs in self.items:
            p = tf.paragraphs[0] if first else tf.add_paragraph()
            first = False
            s = size if level <= 0 else size - 1
            _para_format(p, s, space_after=s * BULLET_GAP)
            if level < 0:
                _no_bullet(p)
            else:
                _bullet(p, "▪" if level == 0 else "–", ACCENT if level == 0 else MUTED,
                        INDENT[min(level, 1)])
            _write_runs(p, runs, s)
        return h


class Code:
    def __init__(self, text):
        self.lines = text.rstrip("\n").split("\n")
        self.cols = max((len(ln.expandtabs(8)) for ln in self.lines), default=1)

    PAD = Inches(0.14)

    def size_for(self, size, width):
        adv = text_width("M", 1000, mono=True) / 1000      # EMU per point per character
        fit = (width - 2 * self.PAD) * SAFETY / (adv * max(self.cols, 1))
        return max(7.0, min(size - 1, fit))

    def height(self, size, width):
        s = self.size_for(size, width)
        return len(self.lines) * s * 1.12 * EMU_PT + 2 * self.PAD

    def draw(self, slide, x, y, width, size):
        s = self.size_for(size, width)
        h = self.height(size, width)
        box = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, Emu(int(x)), Emu(int(y)),
                                     Emu(int(width)), Emu(int(h)))
        box.fill.solid()
        box.fill.fore_color.rgb = CODE_BG
        box.line.fill.background()
        box.shadow.inherit = False
        tf = box.text_frame
        _no_autofit(tf, (self.PAD, self.PAD, self.PAD, self.PAD))
        tf.vertical_anchor = MSO_ANCHOR.TOP
        for i, ln in enumerate(self.lines):
            p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
            p.alignment = PP_ALIGN.LEFT
            p.line_spacing = Pt(round(s * 1.12, 1))
            p.space_after = Pt(0)
            run = p.add_run()
            run.text = ln.expandtabs(8) or " "
            run.font.name, run.font.size, run.font.color.rgb = MONO, Pt(round(s * 2) / 2), INK
        return h


class Table:
    CELL_X, CELL_Y = Inches(0.08), Inches(0.05)

    def __init__(self, header, rows, aligns):
        self.header, self.rows, self.aligns = header, rows, aligns
        self.ncols = len(header) if header else len(rows[0])

    def _all_rows(self):
        return ([self.header] if self.header else []) + self.rows

    def col_widths(self, size, width):
        """Share WIDTH between the columns: each gets at least its longest word, and the rest
        goes where the text is, so short columns stay narrow and prose columns get the room."""
        rows = self._all_rows()
        hdr = 1 if self.header else 0
        mins, wants = [], []
        for c in range(self.ncols):
            cells = [(r[c], i < hdr) for i, r in enumerate(rows) if c < len(r)]
            mins.append(max((longest_word([x.like(x.text) for x in cell], size)
                             if not bold else longest_word([Run(plain_text(cell), True)], size)
                             for cell, bold in cells), default=0) / SAFETY + 2 * self.CELL_X)
            wants.append(max((natural_width(cell, size) for cell, _ in cells), default=0)
                         / SAFETY + 2 * self.CELL_X)
        if sum(wants) <= width:
            spare = width - sum(wants)
            return [w + spare * w / sum(wants) for w in wants]
        if sum(mins) >= width:
            return [width * m / sum(mins) for m in mins]
        # Columns whose text fits in less than their proportional share get exactly what they
        # need, so they set on one line; what is left is shared among the rest by need.
        widths, room, open_cols = [0.0] * self.ncols, width, set(range(self.ncols))
        while open_cols:
            tot = sum(wants[c] for c in open_cols)
            fits = {c for c in open_cols if wants[c] <= room * wants[c] / tot
                    or wants[c] <= room / len(open_cols)}
            if not fits:
                for c in open_cols:
                    widths[c] = room * wants[c] / tot
                break
            for c in fits:
                widths[c] = wants[c]
                room -= wants[c]
            open_cols -= fits
        # no column narrower than its longest word
        short = [c for c in range(self.ncols) if widths[c] < mins[c]]
        for c in short:
            take = mins[c] - widths[c]
            widths[c] = mins[c]
            donors = [d for d in range(self.ncols) if d not in short]
            for d in donors:
                widths[d] -= take / len(donors)
        return widths

    def row_heights(self, size, width):
        widths = self.col_widths(size, width)
        out = []
        for i, row in enumerate(self._all_rows()):
            bold = self.header is not None and i == 0
            n = 1
            for c, cell in enumerate(row):
                runs = [r.like(r.text) for r in cell]
                if bold:
                    for r in runs:
                        r.bold = True
                n = max(n, count_lines(runs, size, widths[c] - 2 * self.CELL_X))
            out.append(n * size * LINE * EMU_PT + 2 * self.CELL_Y)
        return widths, out

    def height(self, size, width):
        return sum(self.row_heights(self.tsize(size), width)[1])

    @staticmethod
    def tsize(size):
        return max(BODY_MIN - 1, size - 2)

    def draw(self, slide, x, y, width, size):
        s = self.tsize(size)
        widths, heights = self.row_heights(s, width)
        rows = self._all_rows()
        gf = slide.shapes.add_table(len(rows), self.ncols, Emu(int(x)), Emu(int(y)),
                                    Emu(int(width)), Emu(int(sum(heights))))
        tbl = gf.table
        tblpr = tbl._tbl.tblPr
        for attr in ("firstRow", "bandRow"):
            tblpr.set(attr, "0")
        style = tblpr.find(qn("a:tableStyleId"))
        if style is not None:                      # "No Style, No Grid": every look is set here
            style.text = "{2D5ABB26-0587-4C30-8999-92F81FD0307C}"
        for c, w in enumerate(widths):
            tbl.columns[c].width = Emu(int(w))
        for i, h in enumerate(heights):
            tbl.rows[i].height = Emu(int(h))
        for i, row in enumerate(rows):
            head = self.header is not None and i == 0
            for c in range(self.ncols):
                cell = tbl.cell(i, c)
                cell.margin_left = cell.margin_right = Emu(int(self.CELL_X))
                cell.margin_top = cell.margin_bottom = Emu(int(self.CELL_Y))
                cell.vertical_anchor = MSO_ANCHOR.TOP
                cell.fill.solid()
                cell.fill.fore_color.rgb = ACCENT_PALE if head else WHITE
                runs = [r.like(r.text) for r in (row[c] if c < len(row) else [])]
                if head:
                    for r in runs:
                        r.bold = True
                tf = cell.text_frame
                tf.word_wrap = True
                p = tf.paragraphs[0]
                _para_format(p, s)
                p.alignment = {"AlignRight": PP_ALIGN.RIGHT,
                               "AlignCenter": PP_ALIGN.CENTER}.get(self.aligns[c], PP_ALIGN.LEFT)
                _write_runs(p, runs, s)
                _cell_borders(cell, bottom=ACCENT if head else RULE,
                              width=1.0 if head else 0.75)
        return sum(heights)


def _cell_borders(cell, bottom, width):
    tcpr = cell._tc.get_or_add_tcPr()
    for tag in ("a:lnL", "a:lnR", "a:lnT", "a:lnB"):
        ln = etree.SubElement(tcpr, qn(tag), w=str(int(Pt(width))) if tag == "a:lnB" else "0")
        if tag == "a:lnB":
            fill = etree.SubElement(ln, qn("a:solidFill"))
            etree.SubElement(fill, qn("a:srgbClr"), val=str(bottom))
        else:
            etree.SubElement(ln, qn("a:noFill"))
    # the schema puts borders before the fill
    fill = tcpr.find(qn("a:solidFill"))
    if fill is not None:
        tcpr.remove(fill)
        tcpr.append(fill)


# ---------------------------------------------------------------------------------------------
# From pandoc blocks to body blocks.


def blocks_to_body(blocks):
    body, pending = [], []

    def flush():
        if pending:
            body.append(Bullets(list(pending)))
            pending.clear()

    def list_items(items, level):
        for item in items:
            first = True
            for b in item:
                if b["t"] in ("Plain", "Para"):
                    pending.append((level if first else -1, runs_of(b["c"])))
                    first = False
                elif b["t"] in ("BulletList", "OrderedList"):
                    list_items(b["c"] if b["t"] == "BulletList" else b["c"][1], level + 1)

    for b in blocks:
        t, c = b["t"], b.get("c")
        if t in ("BulletList", "OrderedList"):
            list_items(c if t == "BulletList" else c[1], 0)
        elif t in ("Para", "Plain"):
            pending.append((-1, runs_of(c)))
        elif t == "CodeBlock":
            flush()
            body.append(Code(c[1]))
        elif t == "Table":
            flush()
            body.append(table_of(c))
        elif t == "BlockQuote":
            for q in c:
                if q["t"] in ("Para", "Plain"):
                    pending.append((-1, runs_of(q["c"], italic=True)))
        elif t == "Div":
            body += blocks_to_body(c[1])
        # HorizontalRule, RawBlock: nothing
    flush()
    return body


def table_of(c):
    _, _, colspecs, head, bodies, _ = c
    aligns = [cs[0]["t"] for cs in colspecs]

    def cell_runs(cell):
        runs = []
        for b in cell[4]:
            if b["t"] in ("Plain", "Para"):
                if runs:
                    runs.append(Run("\n"))
                runs += runs_of(b["c"])
        return runs

    def rows_of(rows):
        return [[cell_runs(cell) for cell in row[1]] for row in rows]

    header = rows_of(head[1])
    rows = []
    for body in bodies:
        rows += rows_of(body[2]) + rows_of(body[3])
    return Table(header[0] if header else None, rows, aligns)


# ---------------------------------------------------------------------------------------------
# Slides.


class Deck:
    def __init__(self, title, subtitle, author, date):
        self.prs = Presentation()
        self.prs.slide_width, self.prs.slide_height = SLIDE_W, SLIDE_H
        self.blank = self.prs.slide_layouts[6]
        self.title, self.subtitle, self.author, self.date = title, subtitle, author, date
        self.part = ""

    def new(self):
        s = self.prs.slides.add_slide(self.blank)
        s.background.fill.solid()
        s.background.fill.fore_color.rgb = WHITE
        return s

    def footer(self, s, label):
        simple_text(s, self.title, MX, FOOTER_Y, Inches(9), Inches(0.3), 9, MUTED)
        simple_text(s, label, SLIDE_W - MX - Inches(2), FOOTER_Y, Inches(2), Inches(0.3), 9,
                    MUTED, align=PP_ALIGN.RIGHT)

    def header(self, s, title, kicker):
        """Kicker and title; returns where the body may start."""
        if kicker:
            simple_text(s, kicker.upper(), MX, KICKER_Y, CONTENT_W, Inches(0.3), 11, ACCENT,
                        bold=True, spacing=1.2)
        for size in (28, 25, 22):
            n = count_lines([Run(title, bold=True)], size, CONTENT_W)
            if n == 1:
                break
        h = n * size * LINE * EMU_PT
        simple_text(s, title, MX, TITLE_Y, CONTENT_W, h + Inches(0.05), size, INK, bold=True)
        rule_y = TITLE_Y + h + Inches(0.12)
        line = s.shapes.add_connector(1, Emu(int(MX)), Emu(int(rule_y)), Emu(int(MX + Inches(1.2))),
                                      Emu(int(rule_y)))
        line.line.color.rgb = ACCENT
        line.line.width = Pt(2.25)
        return rule_y + Inches(0.3)

    # The notes page is portrait, 7.5 x 10 in, the slide image above the notes. The notes box
    # gets a fixed place and its text a size that fits it, as the slides do: long notes would
    # otherwise run off the page in the PDF.
    NOTES_BOX = (Inches(0.75), Inches(4.95), Inches(6.0), Inches(4.55))

    def notes(self, s, blocks):
        if not blocks:
            return
        paras = [([Run("\u2022 " if level == 0 else "    \u2013 ")] + runs if level >= 0 else runs)
                 for level, runs in notes_paras(blocks)]
        x, y, w, h = self.NOTES_BOX

        def height(size):
            return sum(count_lines(r, size, w) * size * LINE + size * 0.5 for r in paras) * EMU_PT

        size = next((sz for sz in (12, 11.5, 11, 10.5, 10, 9.5, 9, 8.5, 8) if height(sz) <= h), 8)
        if height(size) > h:
            print(f"deck.py: warning: speaker notes overflow the notes page at 8pt: "
                  f"{plain_text(paras[0])[:60]!r}", file=sys.stderr)
        ph = s.notes_slide.notes_placeholder
        ph.left, ph.top, ph.width, ph.height = Emu(int(x)), Emu(int(y)), Emu(int(w)), Emu(int(h))
        tf = ph.text_frame
        _no_autofit(tf)
        for i, runs in enumerate(paras):
            p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
            _para_format(p, size, space_after=size * 0.5)
            _write_runs(p, runs, size, BODY, INK)

    # -- slide kinds --

    def title_slide(self):
        s = self.new()
        bar = s.shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, 0, Inches(0.35), SLIDE_H)
        bar.fill.solid()
        bar.fill.fore_color.rgb = ACCENT
        bar.line.fill.background()
        simple_text(s, self.title, Inches(1.2), Inches(2.2), Inches(11), Inches(1.6), 44, INK,
                    bold=True, anchor=MSO_ANCHOR.BOTTOM)
        if self.subtitle:
            simple_text(s, self.subtitle, Inches(1.2), Inches(3.95), Inches(11), Inches(0.9), 22,
                        BODY)
        y = Inches(5.3)
        for line, size, color in ((self.author, 18, INK), (self.date, 14, MUTED)):
            if line:
                simple_text(s, line, Inches(1.2), y, Inches(11), Inches(0.45), size, color)
                y += Inches(0.45)

    def part_slide(self, title):
        s = self.new()
        s.background.fill.fore_color.rgb = ACCENT
        m = re.match(r"(Part\s+\S+)\s+[—–-]\s+(.*)", title)
        kicker, name = (m.group(1), m.group(2)) if m else ("", title)
        self.part = title
        if kicker:
            simple_text(s, kicker.upper(), Inches(1.2), Inches(2.6), Inches(11), Inches(0.5), 16,
                        ACCENT_PALE, bold=True, spacing=2)
        simple_text(s, name, Inches(1.2), Inches(3.1), Inches(11), Inches(2.2), 36, WHITE,
                    bold=True)

    def content_slide(self, title, number, blocks, notes):
        s = self.new()
        top = self.header(s, title, self.part)
        self.footer(s, number)
        body = blocks_to_body(blocks)
        if body:
            self.layout_body(s, body, top)
        self.notes(s, notes)

    def figure_slide(self, title, svg, label):
        s = self.new()
        top = self.header(s, title, self.part)
        self.footer(s, label)
        box = (int(MX), int(top), int(CONTENT_W), int(BODY_BOTTOM - top))
        return svg2pptx.draw(svg, s, box)

    # -- body layout: the largest size at which everything fits --

    def layout_body(self, s, body, top):
        avail = BODY_BOTTOM - top
        gaps = BLOCK_GAP * (len(body) - 1)

        def total(size, width):
            return sum(b.height(size, width) for b in body) + gaps

        size = next((sz for sz in range(BODY_MAX, BODY_MIN - 1, -1)
                     if total(sz, CONTENT_W) <= avail), BODY_MIN)

        # A long list of short items reads better, and larger, in two columns.
        if len(body) == 1 and isinstance(body[0], Bullets) and len(body[0].items) >= 9:
            colw = (CONTENT_W - Inches(0.5)) / 2
            items = body[0].items
            def cols(sz):
                half = _split(items, sz, colw)
                return Bullets(items[:half]), Bullets(items[half:])

            size2 = next((sz for sz in range(BODY_MAX, BODY_MIN - 1, -1)
                          if max(b.height(sz, colw) for b in cols(sz)) <= avail), BODY_MIN)
            two = cols(size2)
            if size2 > size:
                two[0].draw(s, MX, top, colw, size2)
                two[1].draw(s, MX + colw + Inches(0.5), top, colw, size2)
                return

        if total(size, CONTENT_W) > avail:
            print(f"deck.py: warning: slide body overflows at {BODY_MIN}pt: "
                  f"{plain_text(_first_runs(body))[:60]!r}", file=sys.stderr)
        y = top
        for b in body:
            y += b.draw(s, MX, y, CONTENT_W, size) + BLOCK_GAP


def _first_runs(body):
    for b in body:
        if isinstance(b, Bullets) and b.items:
            return b.items[0][1]
    return [Run("")]


def _split(items, size, width):
    """Where to cut a list into two columns of nearly equal height, between top-level items."""
    heights = [Bullets([it]).height(size, width) for it in items]
    total, acc, best, best_diff = sum(heights), 0.0, len(items) // 2, None
    for i, h in enumerate(heights[:-1]):
        acc += h
        if items[i + 1][0] > 0:
            continue
        diff = abs(total - 2 * acc)
        if best_diff is None or diff < best_diff:
            best, best_diff = i + 1, diff
    return best


def notes_paras(blocks):
    out = []
    for b in blocks:
        t, c = b["t"], b.get("c")
        if t in ("Para", "Plain"):
            out.append((-1, runs_of(c)))
        elif t in ("BulletList", "OrderedList"):
            for item in (c if t == "BulletList" else c[1]):
                for i, sub in enumerate(item):
                    if sub["t"] in ("Plain", "Para"):
                        out.append((0 if i == 0 else -1, runs_of(sub["c"])))
                    elif sub["t"] in ("BulletList", "OrderedList"):
                        for it in (sub["c"] if sub["t"] == "BulletList" else sub["c"][1]):
                            for x in it:
                                if x["t"] in ("Plain", "Para"):
                                    out.append((1, runs_of(x["c"])))
        elif t == "CodeBlock":
            out.append((-1, [Run(c[1], code=True)]))
        elif t == "BlockQuote":
            out += [(-1, r) for _, r in notes_paras(c)]
        elif t == "Table":
            tb = table_of(c)
            for row in ([tb.header] if tb.header else []) + tb.rows:
                cells = []
                for cell in row:
                    cells += cell + [Run("  |  ")]
                out.append((-1, cells[:-1]))
    return out


# ---------------------------------------------------------------------------------------------
# Reading the deck source.


def parse(src):
    text = open(src, encoding="utf-8").read()
    lines = text.split("\n")
    start = next((i for i, ln in enumerate(lines)
                  if i > 0 and (ln.startswith("# ") or ln.startswith("## "))), 0)
    text = "\n".join(lines[start:])

    # One pandoc call for the whole deck: slide and notes parts become marked Divs.
    out, titles = [], []
    for block in re.split(r"(?m)^(?=#{1,2} )", text):
        if not block.strip():
            continue
        head = block.splitlines()[0]
        if head.startswith("# "):
            titles.append(head[2:].strip())
            out.append(f"::: {{.part idx={len(titles) - 1}}}\n:::\n")
            continue
        m = re.match(r"## (.+?)(?:\s+·\s+([DF]\d+))?\s*$", head)
        title, diag = m.group(1).strip(), m.group(2) or ""
        body = block[len(head):].replace("**On slide**\n", "")
        body = re.sub(r"(?m)^---\s*$", "", body)
        on, notes = (body.split("**Notes**", 1) + [""])[:2]
        titles.append(title)
        out.append(f"::::: {{.slide idx={len(titles) - 1} diag=\"{diag}\"}}\n"
                   f":::: on\n{on.strip()}\n\n::::\n:::: notes\n{notes.strip()}\n\n::::\n:::::\n")
    md = "\n".join(out)
    ast = json.loads(subprocess.run(["pandoc", "-f", "markdown", "-t", "json"], input=md,
                                    capture_output=True, text=True, check=True).stdout)
    slides = []
    for b in ast["blocks"]:
        if b["t"] != "Div":
            continue
        (_, classes, kv), content = b["c"]
        kv = dict(kv)
        if "part" in classes:
            slides.append(("part", titles[int(kv["idx"])]))
        elif "slide" in classes:
            parts = {d["c"][0][1][0]: d["c"][1] for d in content
                     if d["t"] == "Div" and d["c"][0][1]}
            slides.append(("slide", titles[int(kv["idx"])], kv.get("diag", ""), parts.get("on", []),
                           parts.get("notes", [])))
    return slides


def main():
    src, out, diagdir = sys.argv[1:4]
    check_fonts()
    deck = Deck(os.environ.get("DECK_TITLE", "Slides"), os.environ.get("DECK_SUBTITLE", ""),
                os.environ.get("DECK_AUTHOR", ""), os.environ.get("DECK_DATE", ""))
    deck.title_slide()
    tmp = tempfile.mkdtemp()
    seen, figs = set(), 0
    for item in parse(src):
        if item[0] == "part":
            deck.part_slide(item[1])
            continue
        _, title, diag, on, notes = item
        m = re.match(r"(\d+)\s+[—–-]\s+(.*)", title)
        number, name = (m.group(1), m.group(2)) if m else ("", title)
        deck.content_slide(name, number, on, notes)
        if diag and diag not in seen and os.path.isdir(diagdir):
            hits = sorted(f for f in os.listdir(diagdir)
                          if f.startswith(diag + "-") and f.endswith(".svg"))
            if hits:
                seen.add(diag)
                stripped = os.path.join(tmp, diag + ".svg")
                ftitle = figtitle.strip(os.path.join(diagdir, hits[0]), stripped)
                fm = re.match(r"([DF]\d+)\s+—\s+(.*)", ftitle or "")
                n = deck.figure_slide(fm.group(2) if fm else (ftitle or diag), stripped, diag)
                print(f"  {hits[0]}  ->  {n} shapes")
                figs += 1
    cp = deck.prs.core_properties
    cp.title = deck.title
    if deck.subtitle:
        cp.subject = deck.subtitle
    if deck.author:
        cp.author = deck.author
    deck.prs.save(out)
    print(f"\n  {len(deck.prs.slides._sldIdLst)} slides, {figs} diagrams as native shapes")


if __name__ == "__main__":
    main()
