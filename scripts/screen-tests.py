#!/usr/bin/env python3
# Which screens a UI test reaches. For each SwiftUI View in the given source
# files, lists its accessibility identifiers and whether any UI test names one.
# Usage: python3 -I scripts/screen-tests.py SOURCE.swift[,SOURCE.swift...] TESTDIR[,TESTDIR...]
import re, sys, pathlib
srcs = [pathlib.Path(p) for p in sys.argv[1].split(",")]
tests = "".join(p.read_text() for d in sys.argv[2].split(",") for p in pathlib.Path(d).rglob("*.swift"))
for f in srcs:
    text = f.read_text()
    parts = re.split(r"\n(?=(?:public |private |fileprivate )?struct \w+[^{]*: View)", text)
    for part in parts:
        m = re.match(r"(?:public |private |fileprivate )?struct (\w+)", part)
        if not m: continue
        ids = set(re.findall(r"accessibilityIdentifier\((?:AccessibilityID|HousesID)\.(\w+)", part))
        hit = sorted(i for i in ids if re.search(r"(AccessibilityID|HousesID)\." + i + r"\b", tests))
        status = "TESTED" if hit else ("no ids" if not ids else "UNTESTED")
        print(f"{status:9} {f.name}:{m.group(1)}  ids={len(ids)} hit={hit[:3]}")
