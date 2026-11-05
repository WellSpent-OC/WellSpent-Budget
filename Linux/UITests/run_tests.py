"""Runs the Linux UI tests, as `python3 -m unittest -v` does, with test names
the same way. When WELLSPENT_UI_NO_SKIPS is "true", as CI sets it once the
test mailbox's token is there, a test that was skipped fails the run: nothing
is skipped to get a pass. WELLSPENT_UI_LEAVE_OUT names test modules a full
run leaves to a job of their own, such as test_wartable. WELLSPENT_UI_SHARD,
such as "2/3", runs one share of a full run's modules, so CI can run them in
several jobs at once: each module goes to the share with the fewest tests so
far, the largest first, so every module lands in exactly one share. Tests named
on the command line run either way."""

import os
import sys
import unittest


def _flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from _flatten(item)
        else:
            yield item


names = sys.argv[1:]
loader = unittest.TestLoader()
if names:
    suite = loader.loadTestsFromNames(names)
else:
    left_out = os.environ.get("WELLSPENT_UI_LEAVE_OUT", "").split()
    # A module that fails to import comes back as unittest's own stand-in,
    # whose id ends in the module name, so both ends of the id are checked.
    suite = unittest.TestSuite(
        module for module in loader.discover(".", pattern="test_*.py")
        if not any(test.id().split(".")[0] in left_out or test.id().split(".")[-1] in left_out
                   for test in _flatten(module)))
    shard = os.environ.get("WELLSPENT_UI_SHARD", "")
    if shard:
        share, _, shares = shard.partition("/")
        if not (share.isdigit() and shares.isdigit() and 1 <= int(share) <= int(shares)):
            sys.exit(f"run_tests.py: WELLSPENT_UI_SHARD must be SHARE/SHARES, such as 2/3, not {shard}")
        share, shares = int(share), int(shares)
        load = [0] * shares
        mine = []
        modules = sorted(suite, key=lambda module: (-module.countTestCases(), next(_flatten(module)).id()
                                                    if module.countTestCases() else ""))
        for module in modules:
            best = load.index(min(load))
            load[best] += max(module.countTestCases(), 1)
            if best == share - 1:
                mine.append(module)
        suite = unittest.TestSuite(mine)
        print(f"run_tests.py: share {share} of {shares}, {suite.countTestCases()} tests", file=sys.stderr)
result = unittest.TextTestRunner(verbosity=2).run(suite)
if os.environ.get("WELLSPENT_UI_NO_SKIPS") == "true" and result.skipped:
    for test, why in result.skipped:
        print(f"run_tests.py: {test.id()} was skipped ({why}), and none may be.", file=sys.stderr)
    sys.exit(1)
sys.exit(0 if result.wasSuccessful() else 1)
