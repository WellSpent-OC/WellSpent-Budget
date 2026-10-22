"""Runs the Linux UI tests, as `python3 -m unittest -v` does, with test names
the same way. When WELLSPENT_UI_NO_SKIPS is "true", as CI sets it once the
test mailbox's token is there, a test that was skipped fails the run: nothing
is skipped to get a pass."""

import os
import sys
import unittest

names = sys.argv[1:]
loader = unittest.TestLoader()
suite = loader.loadTestsFromNames(names) if names else loader.discover(".", pattern="test_*.py")
result = unittest.TextTestRunner(verbosity=2).run(suite)
if os.environ.get("WELLSPENT_UI_NO_SKIPS") == "true" and result.skipped:
    for test, why in result.skipped:
        print(f"run_tests.py: {test.id()} was skipped ({why}), and none may be.", file=sys.stderr)
    sys.exit(1)
sys.exit(0 if result.wasSuccessful() else 1)
