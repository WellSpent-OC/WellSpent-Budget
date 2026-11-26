"""Reads a UI test run's result, as xcresulttool gives it, and says whether
it passed. A test that needed its retry is listed, and on GitHub it's also
put in the run's summary and given a warning, so a green run still shows it.

    python3 -I scripts/ui-test-outcome.py SUMMARY.json TESTS.json [LOST]

SUMMARY.json is `xcresulttool get test-results summary`, and TESTS.json is
`... tests`. Exits 0 when the run's verdict is Passed, 1 otherwise.

A test that fails and then has the test runner restarted under it (a crash
or a timeout) never gets its retry: the bundle shows it with fewer than two
tries. Given LOST, a file, and when every failed test lost its retry that
way, it names them in LOST, one -only-testing name a line, warns that each
lost its retry, and exits 2, so the caller can run each retry on its own.
A test that failed on both tries still fails the run, with no LOST.

    python3 -I scripts/ui-test-outcome.py SUMMARY.json TESTS.json --retry-of LOST

reads that run of the retries. It passes only when the run passed exactly
the tests LOST names, with none failed or skipped: a name that matched no
test makes xcodebuild run nothing, and the bundle still reads Passed."""

import json
import os
import sys


def read(path):
    with open(path) as source:
        text = source.read().strip()
    return json.loads(text) if text else {}


def only_name(place, test):
    """The -only-testing name: the bundle, the nearest suite and the method."""
    where = place[:1] + place[-1:] if len(place) > 1 else place
    return "/".join(where + (test.removesuffix("()"),))


def results(tests):
    """Each test case's result, by its -only-testing name."""
    found = {}

    def walk(node, place=()):
        if isinstance(node, dict):
            kind = node.get("nodeType")
            if kind in ("Unit test bundle", "UI test bundle", "Test Suite"):
                place = place + (node.get("name"),)
            if kind == "Test Case":
                found[only_name(place, node.get("name"))] = node.get("result")
            for child in node.get("children", []):
                walk(child, place)
        elif isinstance(node, list):
            for child in node:
                walk(child, place)
    walk(tests.get("testNodes", []))
    return found


def outcome(tests):
    """The tests that passed only on a retry, and those that failed on their
    last try, each sorted. Then the failed tests that lost their retry, as
    (name, -only-testing name) in the bundle's order."""
    retried, failed, lost = set(), set(), []

    def walk(node, test=None, place=()):
        if isinstance(node, dict):
            kind = node.get("nodeType")
            if kind in ("Unit test bundle", "UI test bundle", "Test Suite"):
                place = place + (node.get("name"),)
            if kind == "Test Case":
                test = node.get("name")
                if node.get("result") == "Failed":
                    failed.add(test)
                    tries = [child for child in node.get("children", []) if child.get("nodeType") == "Repetition"]
                    if len(tries) < 2:
                        lost.append((test, only_name(place, test)))
            if kind == "Repetition" and node.get("result") == "Failed" and test:
                retried.add(test)
            for child in node.get("children", []):
                walk(child, test, place)
        elif isinstance(node, list):
            for child in node:
                walk(child, test, place)
    walk(tests.get("testNodes", []))
    return sorted(retried - failed), sorted(failed), lost


def main(summary_path, tests_path, lost_path=None):
    summary, tests = read(summary_path), read(tests_path)
    retried, failed, lost = outcome(tests)
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
    if verdict == "Passed":
        return 0
    if lost_path and failed and set(failed) == {name for name, _ in lost}:
        for name, _ in lost:
            print(f"ui-test-outcome: {name} failed, and lost its retry when the test runner restarted")
            if os.environ.get("GITHUB_ACTIONS") == "true":
                print(f"::warning title=Lost its retry::{name} failed, and lost its retry when the test runner restarted")
        with open(lost_path, "w") as out:
            out.write("".join(f"{only}\n" for _, only in lost))
        return 2
    for name in failed:
        print(f"ui-test-outcome: FAILED {name}")
    return 1


def retry_of(summary_path, tests_path, lost_path):
    summary, found = read(summary_path), results(read(tests_path))
    with open(lost_path) as source:
        wanted = [line.strip() for line in source if line.strip()]
    passed = sorted(name for name, result in found.items() if result == "Passed")
    good = summary.get("result") == "Passed" and passed == sorted(wanted) and len(found) == len(wanted)
    for name in wanted:
        if found.get(name) == "Passed" and good:
            print(f"ui-test-outcome: {name} passed on its own retry")
        else:
            print(f"ui-test-outcome: FAILED {name} on its own retry: {found.get(name, 'it did not run')}")
    for name in sorted(set(found) - set(wanted)):
        print(f"ui-test-outcome: {name} ran in the retries' run, though it didn't lose a retry")
    return 0 if good else 1


if __name__ == "__main__":
    if sys.argv[3:4] == ["--retry-of"]:
        sys.exit(retry_of(sys.argv[1], sys.argv[2], sys.argv[4]))
    sys.exit(main(*sys.argv[1:4]))
