"""Reads a UI test run's result, as xcresulttool gives it, and says whether
it passed. A test that needed its retry is listed, and on GitHub it's also
put in the run's summary and given a warning, so a green run still shows it.

    python3 -I scripts/ui-test-outcome.py SUMMARY.json TESTS.json

SUMMARY.json is `xcresulttool get test-results summary`, and TESTS.json is
`... tests`. Exits 0 when the run's verdict is Passed, 1 otherwise."""

import json
import os
import sys


def read(path):
    with open(path) as source:
        text = source.read().strip()
    return json.loads(text) if text else {}


def outcome(tests):
    """The tests that passed only on a retry, and those that failed on their
    last try, each sorted."""
    retried, failed = set(), set()

    def walk(node, test=None):
        if isinstance(node, dict):
            kind = node.get("nodeType")
            if kind == "Test Case":
                test = node.get("name")
                if node.get("result") == "Failed":
                    failed.add(test)
            if kind == "Repetition" and node.get("result") == "Failed" and test:
                retried.add(test)
            for child in node.get("children", []):
                walk(child, test)
        elif isinstance(node, list):
            for child in node:
                walk(child, test)
    walk(tests.get("testNodes", []))
    return sorted(retried - failed), sorted(failed)


def main(summary_path, tests_path):
    summary, tests = read(summary_path), read(tests_path)
    retried, failed = outcome(tests)
    for name in retried:
        print(f"ui-test-outcome: {name} failed once and passed on its retry")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        for name in retried:
            print(f"::warning title=Needed a retry::{name} failed once and passed on its retry")
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary and retried:
        with open(step_summary, "a") as out:
            out.write(f"### Needed a retry: {len(retried)}\n\n")
            out.write("".join(f"- {name}\n" for name in retried) + "\n")
    verdict = summary.get("result")
    print("ui-test-outcome: %s, %s passed, %s failed, %s skipped" % (
        verdict, summary.get("passedTests", 0), summary.get("failedTests", 0), summary.get("skippedTests", 0)))
    for name in failed:
        print(f"ui-test-outcome: FAILED {name}")
    return 0 if verdict == "Passed" else 1


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
