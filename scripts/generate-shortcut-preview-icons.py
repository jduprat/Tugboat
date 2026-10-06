#!/usr/bin/env python3
"""Generate SVG shortcut previews, leaving menu icons unchanged.

Run with Python 3 from any directory. Artwork contains only vector geometry;
no fonts, external resources, embedded bitmaps, or third-party packages.
"""
import json
import math
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Tugboat/Assets.xcassets/ShortcutPreviews"
ICONS = {}


def rect(x, y, w, h, opacity=.7, outline=False):
    style = (f'fill="none" stroke="black" stroke-opacity="{opacity:g}" stroke-width="2"'
             if outline else f'fill="black" fill-opacity="{opacity:g}"')
    return f'<rect x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}" rx="1.5" {style}/>'


def path(d, opacity=1, width=2.5):
    return (f'<path d="{d}" fill="none" stroke="black" stroke-opacity="{opacity:g}" '
            f'stroke-width="{width:g}" stroke-linecap="round" stroke-linejoin="round"/>')


def arrow(x1, y1, x2, y2, head=6):
    angle = math.atan2(y2-y1, x2-x1)
    a = (x2-head*math.cos(angle-math.pi/4), y2-head*math.sin(angle-math.pi/4))
    b = (x2-head*math.cos(angle+math.pi/4), y2-head*math.sin(angle+math.pi/4))
    return path(f'M{x1:g} {y1:g} L{x2:g} {y2:g} M{a[0]:g} {a[1]:g} L{x2:g} {y2:g} L{b[0]:g} {b[1]:g}')


FRAME = rect(7, 9, 82, 54, .4, outline=True)


def region(x, y, w, h):
    return FRAME+rect(11+74*x, 13+46*y, 74*w, 46*h)


def add(name, artwork):
    assert name not in ICONS, name
    ICONS[name] = artwork


# Landscape illustrations match the existing orientation-aware menu artwork.
for name, frame in {
    "leftHalf": (0, 0, .5, 1), "rightHalf": (.5, 0, .5, 1),
    "topHalf": (0, 0, 1, .5), "bottomHalf": (0, .5, 1, .5),
    "topLeft": (0, 0, .5, .5), "topRight": (.5, 0, .5, .5),
    "bottomLeft": (0, .5, .5, .5), "bottomRight": (.5, .5, .5, .5),
    "centerHalf": (.25, 0, .5, 1), "maximize": (0, 0, 1, 1),
    "maximizeHeight": (.3, 0, .4, 1), "almostMaximize": (.09, .09, .82, .82),
    "center": (.27, .25, .46, .5), "centerProminently": (.27, .125, .46, .5),
    "firstThird": (0, 0, 1/3, 1), "centerThird": (1/3, 0, 1/3, 1),
    "lastThird": (2/3, 0, 1/3, 1), "firstTwoThirds": (0, 0, 2/3, 1),
    "centerTwoThirds": (1/6, 0, 2/3, 1), "lastTwoThirds": (1/3, 0, 2/3, 1),
    "firstFourth": (0, 0, .25, 1), "secondFourth": (.25, 0, .25, 1),
    "thirdFourth": (.5, 0, .25, 1), "lastFourth": (.75, 0, .25, 1),
    "firstThreeFourths": (0, 0, .75, 1), "centerThreeFourths": (.125, 0, .75, 1),
    "lastThreeFourths": (.25, 0, .75, 1),
    "topVerticalThird": (0, 0, 1, 1/3), "middleVerticalThird": (0, 1/3, 1, 1/3),
    "bottomVerticalThird": (0, 2/3, 1, 1/3),
    "topVerticalTwoThirds": (0, 0, 1, 2/3), "bottomVerticalTwoThirds": (0, 1/3, 1, 2/3),
    "topLeftThird": (0, 0, 2/3, .5), "topRightThird": (1/3, 0, 2/3, .5),
    "bottomLeftThird": (0, .5, 2/3, .5), "bottomRightThird": (1/3, .5, 2/3, .5),
}.items():
    add(name, region(*frame))

for suffix, rows, cols in [
    ("Sixth", ["top", "bottom"], ["Left", "Center", "Right"]),
    ("Eighth", ["top", "bottom"], ["Left", "CenterLeft", "CenterRight", "Right"]),
    ("Ninth", ["top", "middle", "bottom"], ["Left", "Center", "Right"]),
    ("Twelfth", ["top", "middle", "bottom"], ["Left", "CenterLeft", "CenterRight", "Right"]),
    ("Sixteenth", ["top", "upperMiddle", "lowerMiddle", "bottom"], ["Left", "CenterLeft", "CenterRight", "Right"]),
]:
    for r, row in enumerate(rows):
        for c, col in enumerate(cols):
            add(row+col+suffix, region(c/len(cols), r/len(rows), 1/len(cols), 1/len(rows)))

for direction, endpoints, edge in [
    ("Left", (66, 36, 26, 36), "M16 19 V53"),
    ("Right", (30, 36, 70, 36), "M80 19 V53"),
    ("Up", (48, 50, 48, 24), "M23 17 H73"),
    ("Down", (48, 22, 48, 48), "M23 55 H73"),
]:
    add("move"+direction, FRAME+path(edge, .55)+arrow(*endpoints))

for prefix, growing in [("larger", True), ("smaller", False)]:
    for suffix, axes in [("", "xy"), ("Width", "x"), ("Height", "y")]:
        art = FRAME+rect(30, 25, 36, 22, .28)
        for start, end, axis in [((29, 36), (15, 36), "x"), ((67, 36), (81, 36), "x"),
                                 ((48, 24), (48, 14), "y"), ((48, 48), (48, 58), "y")]:
            if axis in axes:
                a, b = (start, end) if growing else (end, start)
                art += arrow(*a, *b, head=4.5)
        add(prefix+suffix, art)

for operation in ["double", "halve"]:
    for dimension, directions in [("Width", ["Left", "Right"]), ("Height", ["Up", "Down"])]:
        for direction in directions:
            horizontal = dimension == "Width"
            expanding = operation == "double"
            small = (34, 23, 28, 26) if horizontal else (29, 28, 38, 16)
            large = (20, 23, 56, 26) if horizontal else (29, 20, 38, 32)
            art = FRAME+rect(*large, .16, outline=True)+rect(*(large if expanding else small), .28)
            sign = -1 if direction in ["Left", "Up"] else 1
            start, end = (48, 36), ((48+sign*24, 36) if horizontal else (48, 36+sign*18))
            if not expanding:
                start, end = end, start
            add(operation+dimension+direction, art+arrow(*start, *end))

for name, rows, cols in [("tileAll", 2, 2), ("tileRows", 3, 1), ("tileColumns", 1, 3),
                        ("tileActiveApp", 2, 2), ("tileActiveAppRows", 3, 1), ("tileActiveAppColumns", 1, 3)]:
    art = FRAME
    for r in range(rows):
        for c in range(cols):
            art += rect(12+c*75/cols, 14+r*45/rows, 75/cols-3, 45/rows-3, .65)
    if "ActiveApp" in name:
        art += rect(38, 63, 20, 3, 1)
    add(name, art)

for name in ["cascadeAll", "cascadeActiveApp"]:
    art = FRAME
    for x, y in [(18, 16), (29, 25), (40, 34)]:
        art += rect(x, y, 35, 23, .8, outline=True)+rect(x+4, y+4, 27, 3, .5)
    if name == "cascadeActiveApp":
        art += rect(38, 63, 20, 3, 1)
    add(name, art)

add("restore", rect(32, 17, 45, 35, .16)+rect(18, 29, 39, 29, .35)
    +path("M65 45 A19 19 0 1 0 36 20 L29 27 M29 15 V27 H41"))
add("reverseAll", rect(21, 21, 43, 32, .24)
    +path("M76 38 A27 24 0 0 0 29 20 L23 27 M23 15 V27 H35")
    +path("M20 36 A27 24 0 0 0 67 52 L73 45 M73 57 V45 H61"))
add("specified", FRAME+rect(25, 23, 46, 26, .3)
    +path("M25 18 V12 M71 18 V12 M20 23 H14 M20 49 H14 M76 23 H82 M76 49 H82 M25 54 V60 M71 54 V60", .8, 2))
add("leftTodo", FRAME+rect(12, 14, 19, 44, .75)+rect(36, 14, 48, 44, .2))
add("rightTodo", FRAME+rect(65, 14, 19, 44, .75)+rect(12, 14, 48, 44, .2))

for name, leftward in [("previousDisplay", True), ("nextDisplay", False)]:
    art = rect(7, 17, 33, 28, .35, outline=True)+rect(56, 17, 33, 28, .8, outline=True)
    art += path("M23 45 V51 M14 51 H32 M72 45 V51 M63 51 H81", .55, 2)
    a, b = ((65, 32), (30, 32)) if leftward else ((30, 32), (65, 32))
    add(name, art+arrow(*a, *b))

# Outlined digits avoid font substitution during SVG compilation.
digits = {
    "One": "M42 24 L48 19 V47 M42 47 H54",
    "Two": "M39 25 C39 17 57 17 57 25 C57 32 39 38 39 47 H57",
    "Three": "M39 22 C57 12 64 33 47 33 C64 33 59 55 39 45",
    "Four": "M53 47 V19 L38 38 H60", "Five": "M58 19 H40 V32 C62 26 63 53 39 46",
    "Six": "M56 20 C35 12 32 51 49 48 C65 45 57 24 39 33", "Seven": "M38 19 H59 L44 47",
    "Eight": "M48 33 C29 33 35 15 48 18 C61 15 67 33 48 33 C27 33 34 52 48 48 C62 52 69 33 48 33",
    "Nine": "M40 47 C61 55 64 16 47 19 C31 22 39 43 57 34",
}
for number, digit in digits.items():
    add("display"+number, rect(14, 10, 68, 47, .45, outline=True)
        +path("M48 57 V64 M34 64 H62", .6, 2)+path(digit, 1, 3))


def main():
    source = (ROOT / "Tugboat/WindowAction.swift").read_text().split("// Order matters here", 1)[0]
    actions = set(re.findall(r"\b(\w+)\s*=\s*\d+", source))
    missing, extra = actions-ICONS.keys(), ICONS.keys()-actions
    if missing or extra:
        raise ValueError(f"Coverage mismatch: missing={sorted(missing)}, extra={sorted(extra)}")
    CATALOG.mkdir(parents=True, exist_ok=True)
    (CATALOG / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2)+"\n")
    for action, art in sorted(ICONS.items()):
        name = action+"PreviewTemplate"
        directory = CATALOG / (name+".imageset")
        directory.mkdir(exist_ok=True)
        (directory / (name+".svg")).write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="96" height="72" viewBox="0 0 96 72">\n'+art+'\n</svg>\n')
        (directory / "Contents.json").write_text(json.dumps({
            "images": [{"filename": name+".svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
        }, indent=2)+"\n")
    print(f"Generated {len(ICONS)} SVG preview assets; all WindowAction cases covered.")


if __name__ == "__main__":
    main()
