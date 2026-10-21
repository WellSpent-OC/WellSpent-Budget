#!/usr/bin/env bash
#
# Line coverage of the iPhone's own screens, with a floor.
#
# Sources/WellSpentAppCore/Phone/ builds for iOS only, so coverage.sh, which
# runs on the Mac, never sees it. The iPhone UI tests run it on a simulator
# with coverage on, and this reads their result bundles.
#
#   scripts/phone-coverage.sh RESULT.xcresult [RESULT.xcresult ...]
#
# Each bundle is one run, such as the light look and the dark look. For each
# file the run that covered the most lines counts. That never overstates: the
# runs together cover at least that much.
#
# It fails when no file under Phone/ is in the bundles at all, so a run that
# measured only the app's own target can never pass as full marks.
set -euo pipefail

MINIMUM="${COVERAGE_MINIMUM:-90}"
[ $# -ge 1 ] || { echo "usage: scripts/phone-coverage.sh RESULT.xcresult [RESULT.xcresult ...]" >&2; exit 2; }

reports=()
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for bundle in "$@"; do
  [ -d "$bundle" ] || { echo "No result bundle at $bundle" >&2; exit 1; }
  report="$work/report-${#reports[@]}.json"
  xcrun xccov view --report --json "$bundle" > "$report"
  reports+=("$report")
done

python3 - "$MINIMUM" "${reports[@]}" <<'PY'
import json, sys

minimum = float(sys.argv[1])
marker = "/Sources/WellSpentAppCore/Phone/"
files = {}  # path: (executable lines, most lines covered in any run)
for path in sys.argv[2:]:
    with open(path) as handle:
        report = json.load(handle)
    for target in report.get("targets", []):
        for entry in target.get("files", []):
            name = entry.get("path", "")
            if marker not in name:
                continue
            executable = entry.get("executableLines", 0)
            covered = entry.get("coveredLines", 0)
            before = files.get(name, (executable, 0))
            files[name] = (max(before[0], executable), max(before[1], covered))

if not files:
    print(f"FAIL: no file under {marker.strip('/')} in the coverage. Was the package's code measured?")
    sys.exit(1)

executable = sum(lines for lines, _ in files.values())
covered = sum(lines for _, lines in files.values())
for name, (lines, hit) in sorted(files.items()):
    share = 100.0 * hit / lines if lines else 100.0
    print(f"{share:6.2f}%  {hit:5d}/{lines:<5d}  {name.split(marker)[-1]}")
total = 100.0 * covered / executable if executable else 100.0
print(f"\niPhone screens line coverage: {total:.2f}%  (floor {minimum:.0f}%)")
if total < minimum:
    print(f"FAIL: the iPhone screens' line coverage {total:.2f}% is below the {minimum:.0f}% floor")
    sys.exit(1)
print("iPhone coverage gate passed.")
PY
