#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Benoît Dupont de Dinechin
# SPDX-License-Identifier: Apache-2.0
"""Lift a figure's own title out of its SVG, so a slide can carry it in the title bar instead.

A figure drawn for a document carries its title inside the drawing ("F3 — ... address map"). On a
slide that title is a duplicate of the frame title at best, and at worst the frame title is only
the bare id "F3" while the real title sits in small type inside the figure. This finds the title
text, removes it, drops the white backing the figure was drawn on, and crops the freed band off
the top of the viewBox, so the figure gets the vertical space back.

    figtitle.py in.svg out.svg     writes the stripped SVG and prints the title, or nothing

A title is the first <text> whose whole content reads "<id> — <words>", id being D or F plus
digits. With none, out.svg is a plain copy and nothing is printed, so callers fall back to their
old behaviour.
"""

import re
import shutil
import sys
import xml.etree.ElementTree as ET

SVG = "http://www.w3.org/2000/svg"
NS = "{" + SVG + "}"
TITLE_RE = re.compile(r"^\s*([DF]\d+)\s+—\s+(\S.*?)\s*$")

ET.register_namespace("", SVG)
ET.register_namespace("xlink", "http://www.w3.org/1999/xlink")


def _num(value, default=0.0):
    m = re.match(r"\s*(-?[\d.]+)", value or "")
    return float(m.group(1)) if m else default


def _ty_scale(transform):
    """Vertical translate and uniform scale of a transform list, applied left to right."""
    ty, s = 0.0, 1.0
    for name, args in re.findall(r"(\w+)\s*\(([^)]*)\)", transform or ""):
        vals = [float(v) for v in re.split(r"[\s,]+", args.strip()) if v]
        if name == "translate":
            ty += s * (vals[1] if len(vals) > 1 else 0.0)
        elif name == "scale":
            s *= vals[0]
    return ty, s


def _is_white(el):
    return (el.get("fill") or "").lower() in ("white", "#fff", "#ffffff")


def strip(svg_in, svg_out):
    tree = ET.parse(svg_in)
    root = tree.getroot()
    parent = {c: p for p in root.iter() for c in p}

    found = None
    for el in root.iter(NS + "text"):
        m = TITLE_RE.match("".join(el.itertext()))
        if m:
            found = (el, f"{m.group(1)} — {m.group(2)}")
            break
    if not found:
        shutil.copyfile(svg_in, svg_out)
        return None
    el, title = found

    # Where the title sits in viewBox units: compose the transforms of its ancestors.
    chain, p = [], el
    while p in parent:
        p = parent[p]
        chain.append(p)
    ty, s = 0.0, 1.0
    for anc in reversed(chain):
        aty, ascale = _ty_scale(anc.get("transform"))
        ty, s = ty + s * aty, s * ascale
    font = _num(el.get("font-size"), 14.0) * s
    bottom = ty + s * _num(el.get("y")) + 0.6 * font          # descent plus a small gap
    parent[el].remove(el)

    vb = [float(v) for v in (root.get("viewBox") or "").split()]
    if len(vb) != 4:
        tree.write(svg_out, encoding="utf-8", xml_declaration=True)
        return title
    vx, vy, vw, vh = vb

    # The white backing: Graphviz draws it as the first polygon of the graph group, a hand-drawn
    # figure as a full-width rect. Cropped, it would poke above the new top edge.
    for g in root.iter(NS + "g"):
        polys = [c for c in g if c.tag == NS + "polygon"]
        if polys and _is_white(polys[0]) and (polys[0].get("stroke") or "") in (
                "", "none", "transparent"):
            g.remove(polys[0])
            break
    for r in list(root):
        if r.tag == NS + "rect" and _num(r.get("width")) >= vw and _is_white(r):
            root.remove(r)
            break

    cut = bottom - vy
    if 0 < cut < vh / 2:
        root.set("viewBox", f"{vx:g} {vy + cut:g} {vw:g} {vh - cut:g}")
        h = root.get("height")
        if h:
            unit = re.sub(r"[-\d.\s]", "", h)
            root.set("height", f"{_num(h) * (vh - cut) / vh:.2f}{unit}")
    tree.write(svg_out, encoding="utf-8", xml_declaration=True)
    return title


if __name__ == "__main__":
    t = strip(sys.argv[1], sys.argv[2])
    if t:
        print(t)
