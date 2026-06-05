#!/usr/bin/env python3
"""Erzeugt aus der Google-Variable-Font 'Caveat[wght].ttf' eine statische
Schrift mit dem Familiennamen 'Caveat SemiBold' (Gewicht 600), damit LibreOffice
die in den PowerPoints referenzierte Schrift 'Caveat SemiBold' exakt findet.

Aufruf: make_caveat_semibold.py <Caveat[wght].ttf> <Ausgabe.ttf>
"""
import sys

from fontTools import ttLib
from fontTools.varLib.instancer import instantiateVariableFont

FAMILY = "Caveat SemiBold"


def main(src, dst):
    font = ttLib.TTFont(src)
    # Variable Font auf SemiBold (Gewicht 600) fixieren
    instantiateVariableFont(font, {"wght": 600}, inplace=True)

    name = font["name"]
    # Windows-Records (Platform 3, Encoding 1, US-Englisch) setzen
    name.setName(FAMILY, 1, 3, 1, 0x409)          # Family
    name.setName("Regular", 2, 3, 1, 0x409)       # Subfamily
    name.setName(FAMILY, 4, 3, 1, 0x409)          # Full name
    name.setName(FAMILY.replace(" ", ""), 6, 3, 1, 0x409)  # PostScript name
    name.setName(FAMILY, 16, 3, 1, 0x409)         # Typographic Family
    name.setName("Regular", 17, 3, 1, 0x409)      # Typographic Subfamily

    font.save(dst)
    print(f"Erzeugt: {dst} (Familie '{FAMILY}')")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
