# VCarve Review Gadgets

Pre-flight review gadgets for The Bodgery's beginner CNC router class projects. An instructor runs one against a student's open VCarve file before their machine appointment, and it reports setup and toolpath problems against that project's written instructions.

| Gadget | Project |
|---|---|
| `BoxProjectReviewReport` | Box Project (built with Vectric's Box Creator gadget) |
| `ClockReviewReport` | Dragonfly Clock |
| `CribbageBoardReviewReport` | Small Cribbage Board |

## Status: beta (0.x)

These are working tools in regular use, shared as-is. They have rough edges. A flag doesn't always mean the student's file is wrong, and a clean report doesn't mean every problem was caught. Use them as a second set of eyes, not as a verdict, and please report anything that looks wrong (see below).

## Installing

1. Copy each folder under `Review/` (each one holds a `.lua` and a `.html` file) into:

   `C:\ProgramData\Vectric\VCarve Pro Trial Edition\V12.5\Gadgets\Review\`

   `ProgramData` is hidden by default. Paste the path into Explorer's address bar to get there.
2. Restart VCarve if the gadgets don't show up under the Gadgets menu.

To update, copy the folders again and overwrite the old ones.

## Using

1. Open the student's file in VCarve.
2. Run **Gadgets > Review > (project) Review Report**.
3. A dialog shows a short summary with WARNINGS and ERRORS. For the full report, with every check including the ones that passed, set `VERBOSE_OUTPUT = true` near the top of the `.lua` file and run it again.

**Don't save the student's file after running a gadget** unless you mean to keep the changes. Each gadget recalculates every toolpath, because that's the only way to catch a toolpath whose source vectors were deleted. As a side effect, VCarve marks the file as modified even when nothing was wrong. Close without saving.

## Known gaps

**All gadgets**
- Per-pass depths and tab placement can't be read through the Gadget API, so they appear as standing manual-check warnings on every run.
- Tolerance checks other than overcut don't yet have the floating-point boundary allowance added in v0.10.0. A value sitting exactly on a tolerance edge, such as a Box Allowance of exactly 0.008" or 0.012", could still be flagged incorrectly.

**Box Project**
- The check that "Machine Bed" Z-zero corresponds to VCarve's `Z_BOTTOM` setting hasn't been confirmed.
- The toolpath recalculation check hasn't been tested on a real Box file with deleted source vectors.

**Dragonfly Clock**
- The numbers-ring position checks (centering, radial and angular outliers) are **disabled**. VCarve's "Text in a Box" sizes 10, 11, and 12 differently from the single digits, which made the checks give false positives. The number *count* check is still active. The code comments have the full history.
- Several branches have never fired on a real file: the "V-bit must follow the cutout" rule, and the ambiguous cases (circle count other than 2, more than one pocket, a number count other than 12, zero or two-plus cutouts, no dragonfly objects left over).

**Small Cribbage Board**
- Thresholds are in inches with no conversion for jobs set up in mm. A metric job will produce wrong flags.

## Versions

Each gadget shows its version in the report header (for example `BOX PROJECT REVIEW SUMMARY v0.10.0`). Each gadget is numbered separately:

- **Third digit:** any commit that changes the file
- **Second digit:** any change to what the report says, including fixes
- **First digit:** ready to share beyond the current testers (0.x = beta)

## Reporting a problem

Include:
- the gadget and the version from the report header
- the exact flagged message
- what you expected instead

Please **don't attach student files to GitHub issues or PRs**, since this repo is public. Send them to Mike directly.

## Development notes

The `.lua` files here are the source of truth. Edit them in the repo, then copy them to the ProgramData folder above to test. Each file's header comment lists the checks it makes, and every non-obvious decision is documented inline next to the code it affects.
