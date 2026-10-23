---
title: "Side quest: When a statement won't import"
---

# Side quest: When a statement won't import

> *Some scrolls are written in a tongue we can't read.*

WellSpent reads statement files saved as CSV (comma-separated values), OFX (Open Financial Exchange) or QFX (Quicken Financial Exchange). It can't read a PDF. When it can't read a file, it says why, and nothing is added.

- **"… is not a statement this app can read.":** download the statement again as CSV, OFX or QFX, and import that.
- **"… has no entries to import.":** WellSpent found no line it could read. The file may have no transactions in it. Or its dates may be written in a way WellSpent can't read, such as with a time or a month name. Download it again for dates that have some, or as OFX or QFX.
- **"Line 1 of … could not be read: no amount column.":** download it again as another of the three types.

Still stuck? Write to **dev@wellspent.space** with your bank's name and the type of file you tried. Don't send the file itself, because it has your bank details.

## On Linux

The messages and the fixes are the same on Linux.

## Related

- [Side quest: Download a statement from your bank](download-a-statement.md)
- [Quest 6: Bring in your first statement](bring-in-your-first-statement.md)

<!-- Scenarios: IMPORT-13 -->
