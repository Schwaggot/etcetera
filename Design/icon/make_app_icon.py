#!/usr/bin/env python3
"""Splits poppins-icon.svg into the layers of the app's Icon Composer
document: the gradient as background, the glyphs as foreground. icon.json,
which holds the layer settings, is left alone."""

import copy
import os
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "..", "App", "Etcetera", "Etcetera", "AppIcon.icon", "Assets")
SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)


def q(tag):
    return "{%s}%s" % (SVG, tag)


def layer(children):
    svg = ET.Element(q("svg"), {"width": "1024", "height": "1024", "viewBox": "0 0 1024 1024"})
    for child in children:
        svg.append(copy.deepcopy(child))
    return ET.tostring(svg, encoding="unicode") + "\n"


root = ET.parse(os.path.join(HERE, "poppins-icon.svg")).getroot()
layers = {
    "background.svg": layer([root.find(q("defs")), root.find(q("rect"))]),
    "glyphs.svg": layer([root.findall(q("g"))[-1]]),
}
os.makedirs(ASSETS, exist_ok=True)
for name, body in layers.items():
    with open(os.path.join(ASSETS, name), "w") as f:
        f.write(body)
