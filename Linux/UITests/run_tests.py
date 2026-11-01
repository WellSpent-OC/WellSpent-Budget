"""Runs the Linux UI tests, as `python3 -m unittest -v` does, with test names
the same way. When WELLSPENT_UI_NO_SKIPS is "true", as CI sets it once the
test mailbox's token is there, a test that was skipped fails the run: nothing
is skipped to get a pass. WELLSPENT_UI_LEAVE_OUT names test modules a full
run leaves to a job of their own, such as test_wartable. Tests named on the
command line run either way."""

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
    suite = unittest.TestSuite(
        module for module in loader.discover(".", pattern="test_*.py")
        if not any(test.id().split(".")[0] in left_out for test in _flatten(module)))
result = unittest.TextTestRunner(verbosity=2).run(suite)
if os.environ.get("WELLSPENT_UI_NO_SKIPS") == "true" and result.skipped:
    for test, why in result.skipped:
        print(f"run_tests.py: {test.id()} was skipped ({why}), and none may be.", file=sys.stderr)
    sys.exit(1)
sys.exit(0 if result.wasSuccessful() else 1)
