#!/usr/bin/env python3
"""Benennt pdftoppm-Ausgaben einheitlich auf slide-001.png, slide-002.png, ...

pdftoppm nummeriert je nach Seitenzahl unterschiedlich (slide-1.png bei <10
Seiten, slide-01.png bei <100 ...). Der Player/Manifest erwartet dreistellig.
"""
import os
import re
import sys


def main(directory):
    files = [f for f in os.listdir(directory) if re.fullmatch(r"slide-\d+\.png", f)]
    by_num = sorted(files, key=lambda f: int(re.search(r"(\d+)", f).group(1)))
    # Zweistufig umbenennen, um Kollisionen zu vermeiden (z. B. slide-01 -> slide-001)
    for i, f in enumerate(by_num, start=1):
        tmp = os.path.join(directory, f".__tmp_{i:03d}.png")
        os.rename(os.path.join(directory, f), tmp)
    for i in range(1, len(by_num) + 1):
        os.rename(os.path.join(directory, f".__tmp_{i:03d}.png"),
                  os.path.join(directory, f"slide-{i:03d}.png"))
    print(f"{len(by_num)} Folien normalisiert in {directory}")


if __name__ == "__main__":
    main(sys.argv[1])
