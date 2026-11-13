#!/usr/bin/env python3
"""Fails if the app's Package.resolved pins SwiftCrossUI or a package only it brings in.

SwiftCrossUI is Linux only. The kit and Properties declare it inside
`#if os(Linux)`, so a Mac resolve never sees it. If it ever comes back into the
committed file, Xcode 26.6 crashes reading that file with Properties linked
("insertObjects:atIndexes: count of array differs from count of index set").

Usage: check-mac-pins.py [Package.resolved]
"""
import json
import sys

# SwiftCrossUI, and what only SwiftCrossUI brings into this app's graph.
# General packages it also uses (swift-log, swift-syntax, swift-collections and
# the like) are left off, so the app can still depend on them directly.
LINUX_ONLY = {
    "swift-cross-ui",
    "androidkit",
    "swift-android-native",
    "swift-java",
    "swift-java-jni-core",
    "swiftjavalang",
    "swiftkotlin",
    "swift-winui",
    "swift-image-formats",
    "swift-macro-toolkit",
    "swift-observation-polyfill",
    "jpeg",
    "libpng",
    "libwebp",
}


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "Package.resolved"
    with open(path) as f:
        pins = {pin["identity"].lower() for pin in json.load(f)["pins"]}
    found = sorted(pins & LINUX_ONLY)
    if found:
        print(f"{path} pins Linux-only packages: {', '.join(found)}.")
        print("SwiftCrossUI belongs to Linux builds only, and Xcode 26.6 crashes on this file.")
        print("Resolve on a Mac with a kit and Properties that declare it inside #if os(Linux).")
        return 1
    print(f"{path}: no Linux-only packages pinned.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
