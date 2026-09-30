#!/usr/bin/env python3
"""Compares two folders file by file. Names are compared in Unicode NFC form,
because macOS can report the same name composed or decomposed.

The hidden .burn checksum folder that Burn adds at a disc's root is skipped.

Usage: compare-trees.py SOURCE COPY
"""
import os
import sys
import unicodedata


def files(root):
    result = {}
    for folder, folders, names in os.walk(root):
        if os.path.samefile(folder, root) and ".burn" in folders:
            folders.remove(".burn")
        for name in names:
            if name == ".DS_Store":
                continue
            path = os.path.join(folder, name)
            relative = unicodedata.normalize("NFC", os.path.relpath(path, root))
            result[relative] = path
    return result


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    source, copy = files(sys.argv[1]), files(sys.argv[2])
    problems = 0
    for name in sorted(set(source) - set(copy)):
        print(f"Missing from copy: {name}")
        problems += 1
    for name in sorted(set(copy) - set(source)):
        print(f"Only in copy: {name}")
        problems += 1
    for name in sorted(set(source) & set(copy)):
        with open(source[name], "rb") as a, open(copy[name], "rb") as b:
            if a.read() != b.read():
                print(f"Contents differ: {name}")
                problems += 1
    print(f"Compared {len(source)} files: {'match' if problems == 0 else f'{problems} problems'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
