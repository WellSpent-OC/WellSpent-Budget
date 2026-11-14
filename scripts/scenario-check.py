#!/usr/bin/env python3
"""Checks that the UI tests name the scenarios in Features/ the way its README says.

    python3 -I scripts/scenario-check.py [--require PLATFORM ...] [--require-all] [--list]
        [--root DIR] [--tests PLATFORM=FOLDER ...] [--also DIR]

Each scenario is a "## ID Title" heading in a Features/*.md file. A "Platforms:" line
right under it says where it applies; no line means Mac, Linux and iPhone. A UI test
names the scenarios a step checks with one comment line, "// Scenario PAGE-02,
PAGE-03" in Swift or "# Scenario PAGE-02" in Python.

Always fails on:
- a tag naming a scenario that does not exist,
- a tag on a platform its scenario does not name,
- a row in Features/README.md that does not match the scenarios and the tags.

The per-platform counts are printed, not kept in the README: a count every pull
request changed was a merge conflict every time two were open.

With --require PLATFORM it also fails while a scenario on that platform has no
test there (the Definition of Done, item 3). It may be given more than once, so
each platform is locked the day its last test is written. --require-all
requires every platform. --list prints the scenarios still without a test.

Another repo, such as a private extension's, is checked the same way:
--root is that repo, and each --tests says where one platform's UI tests live in
it, relative to the root; only those platforms' tests are read. --also reads
the scenarios in another repo's Features/ too, so an ID written in both fails,
and a tag may name one of them. Those are not counted and need no row here.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_PLATFORMS = ("Mac", "Linux", "iPhone")
PLATFORMS = APP_PLATFORMS + ("Server", "Connector")
# Where each platform's UI tests live in this repo, and the files that hold them.
TESTS = {
    "Mac": [("Tests/WellSpentUITests", "*.swift")],
    "Linux": [("Linux/UITests", "*.py"), ("Linux/UITests", "*.swift")],
    "iPhone": [("iOS/UITests", "*.swift")],
    "Server": [("Server/Tests", "*.swift")],
    "Connector": [("Extensions/WarTable/adapter/tests", "test_*.py")],
}
# The files a --tests folder is read for.
PATTERNS = ("*.swift", "*.py")
HEADING = re.compile(r"^## ([A-Z]+-\d+) (.+?)\s*$")
TAG = re.compile(r"^\s*(?://|#)\s*Scenario\s+(.+?)\s*$")
ID = re.compile(r"[A-Z]+-\d+")
ROW = re.compile(r"^\|\s*([A-Z]+-\d+)\s*\|(.*)\|\s*$")


def platforms_named(text):
    names = {part.strip() for part in text.split(",") if part.strip()}
    unknown = names - set(PLATFORMS)
    return names, unknown


def read_scenarios(features, problems, scenarios=None):
    scenarios = {} if scenarios is None else scenarios  # ID: (title, set of platforms, file)
    for path in sorted(features.glob("*.md")):
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
                where = set(APP_PLATFORMS)
            if identifier in scenarios:
                problems.append(f"{path.name}: {identifier} is written twice")
            scenarios[identifier] = (title, where, path.name)
    return scenarios


def read_tags(root, tests, scenarios, own, problems):
    tested = {name: set() for name in PLATFORMS}
    for platform, places in tests.items():
        for folder, pattern in places:
            folder = root / folder
            if not folder.is_dir():
                continue
            for path in sorted(folder.rglob(pattern)):
                for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                    match = TAG.match(line)
                    if not match:
                        continue
                    where = f"{path.relative_to(root)}:{number}"
                    for identifier in ID.findall(match.group(1)):
                        if identifier not in scenarios:
                            problems.append(f"{where}: no scenario {identifier} in Features/")
                        elif platform not in scenarios[identifier][1]:
                            problems.append(f"{where}: {identifier} is not on {platform}")
                        elif identifier in own:
                            tested[platform].add(identifier)
    return tested


def check_readme(features, scenarios, tested, problems):
    readme = (features / "README.md").read_text(encoding="utf-8").splitlines()
    rows = {}
    for line in readme:
        if match := ROW.match(line):
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


def options(arguments):
    """--root, every --tests, --also and every --require, read from the arguments."""
    root, also, tests = ROOT, None, {}
    required = set(PLATFORMS) if "--require-all" in arguments else set()
    for index, argument in enumerate(arguments):
        value = arguments[index + 1] if index + 1 < len(arguments) else None
        if argument in ("--root", "--also", "--tests", "--require") and (value is None or value.startswith("--")):
            raise SystemExit(f"scenario check: {argument} needs a value after it")
        if argument == "--root":
            root = pathlib.Path(value).resolve()
        elif argument == "--also":
            also = pathlib.Path(value).resolve()
        elif argument == "--tests":
            platform, _, folder = (value or "").partition("=")
            if platform not in PLATFORMS or not folder:
                raise SystemExit(f"scenario check: --tests wants PLATFORM=FOLDER, one of {', '.join(PLATFORMS)}")
            tests.setdefault(platform, []).extend((folder, pattern) for pattern in PATTERNS)
        elif argument == "--require":
            if value not in PLATFORMS:
                raise SystemExit(f"scenario check: --require wants one of {', '.join(PLATFORMS)}, not {value}")
            required.add(value)
    return root, also, tests or TESTS, required


def main(arguments):
    root, also, tests, required = options(arguments)
    problems = []
    own = read_scenarios(root / "Features", problems)
    scenarios = dict(own)
    if also:
        theirs = read_scenarios(also / "Features", [])
        for identifier in sorted(set(theirs) & set(own)):
            problems.append(f"{own[identifier][2]}: {identifier} is also written in {also.name}")
        scenarios = {**theirs, **own}
    tested = read_tags(root, tests, scenarios, own, problems)
    check_readme(root / "Features", own, tested, problems)
    scenarios = own

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
    for name in PLATFORMS:
        if name in required and missing[name]:
            print(f"scenario check: {len(missing[name])} scenarios on {name} have no test there yet, "
                  f"and {name} is required", file=sys.stderr)
    still = sum(len(missing[name]) for name in required)
    if problems or still:
        return 1
    print("scenario check: every tag names a real scenario on its own platform, and the tables match.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
