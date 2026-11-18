#!/usr/bin/env python3
"""This script writes ClipDeck's Lottie animations into ClipDeck/Resources/Animations.

Every file contains only plain shape layers with stroked paths and animated trim paths.
The paths are white so the app can tint them at run time. Each file has one
"reduced motion" marker on the frame that the app shows when nothing may move. A
one-shot also stops on that frame. Edit the geometry here. Run the script. Commit both
the script and the JSON.

    python3 scripts/make-animations.py
"""

import json
import math
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "ClipDeck" / "Resources" / "Animations"
FPS = 60
K = 0.5523  # cubic handle length for a quarter circle, as a fraction of the radius
STILL_MARKER = "reduced motion"  # the name Lottie players look for


def static(value):
    return {"a": 0, "k": value}


def keyframes(frames, ease_out=(0.33, 0), ease_in=(0.67, 1)):
    """frames is a list of (time, value) pairs. Each value is a number or a list."""
    result = []
    for index, (time, value) in enumerate(frames):
        value = value if isinstance(value, list) else [value]
        frame = {"t": time, "s": value}
        if index < len(frames) - 1:
            frame["o"] = {"x": [ease_out[0]], "y": [ease_out[1]]}
            frame["i"] = {"x": [ease_in[0]], "y": [ease_in[1]]}
        result.append(frame)
    return {"a": 1, "k": result}


def stroke(width):
    return {
        "ty": "st", "nm": "Stroke 1",
        "c": static([1, 1, 1, 1]), "o": static(100), "w": static(width),
        "lc": 2, "lj": 2,
    }


def transform(position=(0, 0), scale=(100, 100), rotation=0, opacity=100):
    return {
        "ty": "tr",
        "p": static(list(position)), "a": static([0, 0]), "s": static(list(scale)),
        "r": static(rotation), "o": static(opacity), "sk": static(0), "sa": static(0),
    }


def layer(name, index, shapes, out_point, position, rotation=0, scale=None, opacity=None, start=0):
    return {
        "ddd": 0, "ind": index, "ty": 4, "nm": name, "sr": 1,
        "ks": {
            "o": opacity if opacity else static(100),
            "r": static(rotation),
            "p": static([position[0], position[1], 0]),
            "a": static([0, 0, 0]),
            "s": scale if scale else static([100, 100, 100]),
        },
        "ao": 0,
        "shapes": [{"ty": "gr", "nm": name, "it": shapes}],
        "ip": start, "op": out_point, "st": 0, "bm": 0,
    }


def document(name, width, height, out_point, still, layers):
    """The app shows the still frame when nothing may move. A one-shot stops on that frame."""
    return {
        "v": "5.7.4", "fr": FPS, "ip": 0, "op": out_point, "w": width, "h": height,
        "nm": name, "ddd": 0, "assets": [], "layers": layers,
        "markers": [{"cm": STILL_MARKER, "tm": still, "dr": 0}],
    }


class Path:
    """An open path consists of straight runs and semicircles in Lottie's Bezier form."""

    def __init__(self):
        self.v, self.i, self.o = [], [], []

    def move(self, x, y):
        self.v.append([x, y]); self.i.append([0, 0]); self.o.append([0, 0])

    def line(self, x, y):
        self.move(x, y)

    def semicircle(self, cx, cy, radius, through_top):
        """The path runs from the current vertex (on the circle) to the point opposite it,
        via the top (negative y) or the bottom. It adds the midpoint and the far point."""
        sign = -1 if through_top else 1
        x0, y0 = self.v[-1]
        far = [2 * cx - x0, cy]
        mid = [cx, cy + sign * radius]
        handle = K * radius
        direction = 1 if far[0] > x0 else -1
        self.o[-1] = [0, sign * handle]
        self.v.append(mid); self.i.append([-direction * handle, 0]); self.o.append([direction * handle, 0])
        self.v.append(far); self.i.append([0, sign * handle]); self.o.append([0, 0])

    def circle(self, cx, cy, radius, start_degrees):
        """The full clockwise turn uses four quarter arcs. It starts and ends at the point
        at start_degrees (0 is right, and 90 is down)."""
        handle = K * radius
        for quarter in range(5):
            angle = math.radians(start_degrees + 90 * quarter)
            cos, sin = math.cos(angle), math.sin(angle)
            point = [round(cx + radius * cos, 3), round(cy + radius * sin, 3)]
            tangent = [round(-sin * handle, 3), round(cos * handle, 3)]
            self.v.append(point)
            self.i.append([0, 0] if quarter == 0 else [-tangent[0], -tangent[1]])
            self.o.append([0, 0] if quarter == 4 else tangent)

    def shape(self):
        return {"ty": "sh", "nm": "Path 1", "ks": static({"i": self.i, "o": self.o, "v": self.v, "c": False})}


def paperclip():
    """A wire paperclip draws on, holds, unwinds, and repeats. It sits at a 45-degree
    angle, with the large loop at the top right like the menu bar glyph."""
    s = 1.4
    p = Path()
    p.move(-4 * s, 14 * s)           # inner wire, open end
    p.line(-4 * s, -14 * s)
    p.semicircle(2 * s, -14 * s, 6 * s, through_top=True)
    p.line(8 * s, 16 * s)
    p.semicircle(-2 * s, 16 * s, 10 * s, through_top=False)
    p.line(-12 * s, -16 * s)
    p.semicircle(2 * s, -16 * s, 14 * s, through_top=True)
    p.line(16 * s, 20 * s)           # outer wire, open end

    draw_on, hold_until, unwound, loop_end = 70, 125, 160, 175
    trim = {
        "ty": "tm", "nm": "Trim Paths 1",
        "s": keyframes([(hold_until, 0), (unwound, 100)], ease_out=(0.4, 0), ease_in=(0.2, 1)),
        "e": keyframes([(0, 0), (draw_on, 100)], ease_out=(0.3, 0), ease_in=(0.15, 1)),
        "o": static(0), "m": 1,
    }
    clip = layer("Paperclip", 1, [p.shape(), trim, stroke(5 * s), transform()], loop_end, (60, 62), rotation=45)
    return document("ClipDeck paperclip", 120, 120, loop_end, draw_on, [clip])


def copied():
    """A ring draws on, then a check draws on inside it with a small pop."""
    ring_shape = {"ty": "el", "nm": "Ellipse Path 1", "p": static([0, 0]), "s": static([44, 44]), "d": 1}
    ring_trim = {
        "ty": "tm", "nm": "Trim Paths 1",
        "s": static(0), "e": keyframes([(0, 0), (26, 100)], ease_out=(0.3, 0), ease_in=(0.2, 1)),
        "o": static(0), "m": 1,
    }
    ring = layer("Ring", 1, [ring_shape, ring_trim, stroke(3.5), transform()], 60, (30, 30), rotation=-90)

    check_path = Path()
    check_path.move(-9.5, 0.5)
    check_path.line(-3, 7)
    check_path.line(10.5, -7)
    check_trim = {
        "ty": "tm", "nm": "Trim Paths 1",
        "s": static(0), "e": keyframes([(14, 0), (34, 100)], ease_out=(0.3, 0), ease_in=(0.1, 1)),
        "o": static(0), "m": 1,
    }
    pop = keyframes([(14, [70, 70, 100]), (32, [108, 108, 100]), (46, [100, 100, 100])], ease_out=(0.3, 0), ease_in=(0.2, 1))
    fade = keyframes([(14, 0), (22, 100)])
    check = layer("Check", 2, [check_path.shape(), check_trim, stroke(4), transform()], 60, (30, 30), scale=pop, opacity=fade, start=14)
    return document("ClipDeck copied", 60, 60, 60, 46, [check, ring])


def no_results():
    """A magnifying glass draws in one stroke. The lens starts where the handle meets
    it, then the handle extends to the lower right."""
    center, radius, handle_end = 52.5, 25, 92.5
    p = Path()
    p.circle(center, center, radius, start_degrees=45)
    p.line(handle_end, handle_end)

    drawn = 40
    trim = {
        "ty": "tm", "nm": "Trim Paths 1",
        "s": static(0), "e": keyframes([(0, 0), (drawn, 100)], ease_out=(0.3, 0), ease_in=(0.15, 1)),
        "o": static(0), "m": 1,
    }
    # The layer outlives the last frame, so the still frame shows it.
    glass = layer("Glass", 1, [p.shape(), trim, stroke(7), transform()], drawn + 1, (0, 0))
    return document("ClipDeck no results", 120, 120, drawn, drawn, [glass])


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, build in (("paperclip", paperclip), ("copied", copied), ("noresults", no_results)):
        path = OUT / f"{name}.json"
        path.write_text(json.dumps(build(), separators=(",", ":")) + "\n")
        print(f"wrote {path.relative_to(OUT.parent.parent.parent)} ({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
