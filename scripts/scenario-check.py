#!/usr/bin/env python3
"""Checks that the UI tests name the scenarios in Features/ the way its README says.

    python3 -I scripts/scenario-check.py [--require-all] [--list]

Each scenario is a "## ID Title" heading in a Features/*.md file. A "Platforms:" line
right under it says where it applies; no line means Mac, Linux and iPhone. A UI test
names the scenarios a step checks with one comment line, "// Scenario PAGE-02,
PAGE-03" in Swift or "# Scenario PAGE-02" in Python.

Always fails on:
- a tag naming a scenario that does not exist,
- a tag on a platform its scenario does not name,
- a table in Features/README.md that does not match the scenarios and the tags.

With --require-all it also fails while any scenario has no test on a platform it
names (the Definition of Done, item 3). --list prints those scenarios.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FEATURES = ROOT / "Features"
PLATFORMS = ("Mac", "Linux", "iPhone")
# Where each platform's UI tests live, and the files that hold them.
TESTS = {
    "Mac": [(ROOT / "Tests" / "WellSpentUITests", "*.swift")],
    "Linux": [(ROOT / "Linux" / "UITests", "*.py"), (ROOT / "Linux" / "UITests", "*.swift")],
    "iPhone": [(ROOT / "iOS" / "UITests", "*.swift")],
}
HEADING = re.compile(r"^## ([A-Z]+-\d+) (.+?)\s*$")
TAG = re.compile(r"^\s*(?://|#)\s*Scenario\s+(.+?)\s*$")
ID = re.compile(r"[A-Z]+-\d+")
ROW = re.compile(r"^\|\s*([A-Z]+-\d+)\s*\|(.*)\|\s*$")
COUNT = re.compile(r"^\|\s*(Mac|Linux|iPhone)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*$")


def platforms_named(text):
    names = {part.strip() for part in text.split(",") if part.strip()}
    unknown = names - set(PLATFORMS)
    return names, unknown


def read_scenarios(problems):
    scenarios = {}  # ID: (title, set of platforms, file)
    for path in sorted(FEATURES.glob("*.md")):
        if path.name == "README.md":
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            match = HEADING.match(line)
            if not match:
                continue
            identifier, title = match.groups()
            following = next((later.strip() for later in lines[index + 1:] if later.strip()), "")
            if following.startswith("Platforms:"):
                names, unknown = platforms_named(following[len("Platforms:"):])
                for name in sorted(unknown):
                    problems.append(f"{path.name}: {identifier} names an unknown platform, {name}")
                where = names & set(PLATFORMS)
            else:
                where = set(PLATFORMS)
            if identifier in scenarios:
                problems.append(f"{path.name}: {identifier} is written twice")
            scenarios[identifier] = (title, where, path.name)
    return scenarios


def read_tags(scenarios, problems):
    tested = {name: set() for name in PLATFORMS}
    for platform, places in TESTS.items():
        for folder, pattern in places:
            if not folder.is_dir():
                continue
            for path in sorted(folder.rglob(pattern)):
                for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                    match = TAG.match(line)
                    if not match:
                        continue
                    where = f"{path.relative_to(ROOT)}:{number}"
                    for identifier in ID.findall(match.group(1)):
                        if identifier not in scenarios:
                            problems.append(f"{where}: no scenario {identifier} in Features/")
                        elif platform not in scenarios[identifier][1]:
                            problems.append(f"{where}: {identifier} is not on {platform}")
                        else:
                            tested[platform].add(identifier)
    return tested


def check_readme(scenarios, tested, problems):
    readme = (FEATURES / "README.md").read_text(encoding="utf-8").splitlines()
    rows = {}
    counts = {}
    for line in readme:
        if match := COUNT.match(line):
            counts[match.group(1)] = (int(match.group(2)), int(match.group(3)))
        elif match := ROW.match(line):
            cells = [cell.strip() for cell in match.group(2).split("|")]
            if len(cells) == 3:
                rows[match.group(1)] = cells
    for identifier, (title, where, _) in sorted(scenarios.items()):
        row = rows.get(identifier)
        if row is None:
            problems.append(f"Features/README.md: no row for {identifier}")
            continue
        has = {name for name in PLATFORMS if identifier in tested[name]}
        named, _ = platforms_named(row[1])
        shown, _ = platforms_named("" if row[2] == "None yet" else row[2])
        if row[0] != title:
            problems.append(f"Features/README.md: {identifier}'s title is \"{row[0]}\", not \"{title}\"")
        if named != where:
            problems.append(f"Features/README.md: {identifier}'s platforms are {', '.join(p for p in PLATFORMS if p in where)}")
        if shown != has:
            should = ", ".join(p for p in PLATFORMS if p in has) or "None yet"
            problems.append(f"Features/README.md: {identifier} has a test on {should}, not {row[2]}")
    for identifier in sorted(set(rows) - set(scenarios)):
        problems.append(f"Features/README.md: a row for {identifier}, which is not a scenario")
    for name in PLATFORMS:
        on = sum(1 for _, where, _ in scenarios.values() if name in where)
        expected = (on, len(tested[name]))
        if counts.get(name) != expected:
            found = " and ".join(map(str, counts[name])) if name in counts else "nothing"
            problems.append(f"Features/README.md: {name}'s line should read {expected[0]} and {expected[1]}, "
                            f"not {found}")


def main(arguments):
    require_all = "--require-all" in arguments
    problems = []
    scenarios = read_scenarios(problems)
    tested = read_tags(scenarios, problems)
    check_readme(scenarios, tested, problems)

    missing = {name: sorted(i for i, (_, where, _) in scenarios.items() if name in where and i not in tested[name])
               for name in PLATFORMS}
    print("| Platform | Scenarios on it | Named by a test | Still to write |")
    print("| - | - | - | - |")
    for name in PLATFORMS:
        on = sum(1 for _, where, _ in scenarios.values() if name in where)
        print(f"| {name} | {on} | {len(tested[name])} | {len(missing[name])} |")
    if "--list" in arguments:
        for name in PLATFORMS:
            for identifier in missing[name]:
                print(f"- {name}: {identifier} {scenarios[identifier][0]}")

    for problem in problems:
        print(f"scenario check: {problem}", file=sys.stderr)
    still = sum(len(ids) for ids in missing.values())
    if require_all and still:
        print(f"scenario check: {still} scenario and platform pairs have no UI test yet", file=sys.stderr)
    if problems or (require_all and still):
        return 1
    print("scenario check: every tag names a real scenario on its own platform, and the tables match.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
