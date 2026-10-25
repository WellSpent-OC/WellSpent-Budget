"""Measure this connector's executable lines with Python's standard trace module."""
from pathlib import Path
import sys
import trace
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def run():
    return unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.discover(str(ROOT / "tests")))


if __name__ == "__main__":
    tracer = trace.Trace(count=True, trace=False)
    result = tracer.runfunc(run)
    counts = tracer.results().counts
    covered_total = total = 0
    for path in sorted((ROOT / "wartable_adapter").glob("*.py")):
        # Line zero is the compiler's module marker, not an executable source line.
        executable = {line for line in trace._find_executable_linenos(str(path)) if line and line > 0}
        visited = {line for (filename, line) in counts if filename == str(path)}
        missing = sorted(executable - visited)
        covered = len(executable) - len(missing)
        covered_total += covered
        total += len(executable)
        print(f"{path.name}: {covered}/{len(executable)} lines ({100 * covered / max(1, len(executable)):.2f}%)")
        if "--missing" in sys.argv and missing:
            print("  Missing: " + ",".join(map(str, missing)))
    percent = 100 * covered_total / max(1, total)
    print(f"Connector coverage: {covered_total}/{total} executable lines ({percent:.2f}%); minimum 90%.")
    raise SystemExit(0 if result.wasSuccessful() and percent >= 90 else 1)
