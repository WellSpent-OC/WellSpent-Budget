# The Linux app's UI tests

These tests drive the real Linux app the way a person does, and check what they
see. Each one checks scenarios from `Features/`, and names them, as the Mac's and
the iPhone's UI tests do.

They run on a virtual display nobody sees, as a staging build with data of its
own, so they never open a window on your screen or touch anyone's budgets.

## Running them

On Linux, with Docker, from the repository's top folder:

```
Linux/UITests/run-in-docker.sh                     # all of them
Linux/UITests/run-in-docker.sh test_money_wheel    # one file
```

The first run builds the test image, matching server and app, which takes a few minutes. Later
runs take seconds to build. When a step fails, it says what it waited for, and a
picture of the screen is kept in `.build/uitest/out/`.

The Docker runner starts the server from this checkout on loopback with a fresh
SQLite database and synthetic test mailbox. `Server/scripts/with-ui-fixture.py`
passes its temporary URL and mailbox token directly to the tests and removes
the server and private state afterward. No deployed service or secret is needed.
Skipped tests fail the run.

WarTable's review fixture uses the actual connector to edit a permitted file,
run a networkless syntax check, and create a local Git commit. It publishes no
branch or pull request and starts no model provider. The test container relaxes
Docker's seccomp and AppArmor profiles so bubblewrap can create its nested
namespace; the worker's enforced sandbox remains required. These options apply
only to this disposable test container, whose source mount is read-only.

In CI, the "Linux UI test" job runs the same tests through the disposable-server
helper and `run.sh`, in the same Swift image with the same packages
(`packages.txt`). For a manually prepared local server, `run.sh` accepts
`WELLSPENT_UI_SERVER_URL` and `WELLSPENT_UI_TEST_MAILBOX_TOKEN`; do not point the
WarTable integration fixture at a deployed service.

## How a test finds things

GTK shows every button, text and text box to the desktop's accessibility tree
(AT-SPI), by its role and its words. A test finds "Invite Someone…" by those, the
way a screen reader would, and presses it through the tree. Nothing is clicked by
its place on the screen.

- Things every line has, such as each group's ⋯ and arrow, are found nearest to
  the line they're on (`App.near`).
- Where the Linux app's words alone don't say enough, the app tells a screen
  reader the same things the Mac tells VoiceOver: the arrow's "Show budgets", a
  row's "48 percent used", and which row is picked (`Accessibility.swift`).
- When something can't be found by its role and words, fix the tool or the app's
  accessibility words. Never fall back to a place on the screen.

## A test and its tool stay apart

- **`wellspent_ui.py` is the tool:** finding, pressing, typing, waiting, the
  window's keyboard, and the steps many tests share, such as making a budget. It
  also works out the words the money wheel should show on a given day, with the
  shared code's own arithmetic.
- **`test_*.py` are the tests.** Each states behaviour from its scenarios, in
  steps a person takes, and checks what shows. A test never reaches into how the
  app is built.
- A step that checks a scenario names it on the line above, as on the other
  platforms:

  ```python
  # Scenario PAGE-05
  # 10. The arrow at the end of the group's line hides its budgets.
  ```

  After adding or removing a tag, update the tables in `Features/README.md`.

## Email invitations and old links

`test_sharing.py` and `test_email_invitations.py` use the real email form and
the invitation rows, including Accept, Reject and Cancel Invite. Email goes
only to the tests' example.com recipients through the server's test mailbox.

`legacy_invite_fixture.py` sets up already-sent links through the retained
public v2 API. The unrelated shared-budget, permissions and history tests use
that setup and still join through the real UI. It does not count as testing
the new invitation form, and it reads neither the app's database nor a test-only
app endpoint. No UI test now expects a visible Create Link or Copy Link button.

## Test settings the app takes

A staging build takes the same two settings as the Mac's, and a live build
ignores them:

- `WELLSPENT_DAY_OF_MONTH` pins the money wheel to that day of this month, so a
  test sees mid-month or the month's last week whatever day it runs.
- `WELLSPENT_UNDO_SECONDS` sets how long Undo stays after a delete.

`App.launch(day=…, undo_seconds=…)` sets them.
