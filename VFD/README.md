# CNC Router VFD Settings

This folder records how the router's spindle drive (VFD) is programmed, for each controller setup the machine has used. It exists so that years from now, someone can see exactly how the drive was configured and why, without reading it off the keypad one parameter at a time.

- **Drive:** CDI-EM60 series frequency inverter, in the VFD enclosure on The Bodgery's Techno LC 4896 CNC router.
- **Manual:** *CDI-EM60 Series Frequency Inverter Operation Manual*. Chapter 5 lists all parameters, Chapter 6 explains them. Page numbers in these files refer to that manual.
- **Wiring:** the KiCad project in this repository. The GX16-8 connector on the VFD enclosure brings out every drive signal either spindle controller uses.

## Files

| File | What it is | How often it changes |
|---|---|---|
| `settings.csv` | **The record.** One row per parameter, one column per configuration. | Whenever the drive is reprogrammed |
| `configurations.csv` | What each configuration is: hardware, who set it up, when, status. | When a configuration is added or goes into service |
| `differences.md` | Generated summary: everything not at factory, plus the change list between configurations. **Start here.** | Automatically, after every change |
| `parameters.csv` | Reference: every writable parameter's name, allowed range, factory value, manual page. | Almost never |
| `di_functions.csv`, `output_functions.csv` | What the numbers mean in the DI terminal (P2.0.00–P2.0.05) and relay (P2.0.29) parameters. | Never |
| `verification-checklist.md` | One-time check of the recorded settings against the drive, then saving the drive's backup. **Not yet done.** | Once |
| `motor.md` | The spindle motor's specs and the drive settings that depend on them. | If the spindle is replaced |
| `session-card.md` | Printable procedure for test sessions on the RPM-control controller. | Rarely |
| `tools/` | Scripts that check the files and produce `differences.md`. | Rarely |

## Configurations

The short names are used as column headers in `settings.csv`. Full details are in `configurations.csv`.

| Column | Configuration |
|---|---|
| `factory` | Factory defaults from the manual |
| `freq_control` | Original spindle controller. The user dials in VFD frequency to set spindle speed. |
| `rpm_control` | New spindle controller (designed by Steve Pollack). The user sets the desired RPM directly. |

Each configuration also has a `<name>_note` column for the reason a value differs from factory, e.g. "spindle motor nameplate" or "0–10 V speed signal on VF1". Most notes are empty because most parameters stay at factory.

**Empty cell = not recorded**, not "same as factory." To record that a parameter is at its factory value, enter the factory value.

## How values are written

Values are written the way the keypad shows them, with three adjustments so the files stay unambiguous:

- **Numbers** keep the keypad's decimal places but drop its leading zeros: the keypad's `050.00` is written `50.00`, and `0020.0` is `20.0`.
- **Digit fields**, where each digit position is a separate setting (e.g. P2.1.00, one digit per DI terminal), start with `b`: `b00000`. The `b` stops spreadsheets from turning `00101` into `101`.
- **Hex fields** keep the manual's form: `H.0033`.
- **`machine-type`** in the factory column means the manual doesn't print the factory value because it depends on the drive model. Record the actual value in the configuration columns.

## Viewing and editing

**To view:** open `differences.md` or `settings.csv` on GitHub. GitHub shows CSV files as a searchable table. Opening them in Excel to look at is fine. **Close Excel without saving.** If Excel saves the file, it strips leading zeros and decimal places.

**To change a value** (the normal case):

1. Open `settings.csv` on GitHub and click the pencil icon.
2. Find the row (Ctrl-F the parameter code) and change the value. Add a note if it's not at factory.
3. Click **Commit changes** and write one line saying why, e.g. "rpm_control: DI4 to no function, controller drives run via DI1."

GitHub records who made the change and when. Within a minute or so it checks the file and updates `differences.md`. If something is malformed, the commit gets a red ✗ and the Actions tab explains what's wrong.

**To enter a whole column** (e.g. recording a configuration for the first time), it's easier to edit locally with VS Code and a CSV extension (Rainbow CSV or Edit CSV), then commit with GitHub Desktop or git. Don't use Excel.

**History:** on GitHub, open `settings.csv` and click **History** to see every change, or **Blame** to see who last changed each row and why.

## Adding a configuration

For example, if the controller board is replaced with an Acorn:

```
python3 VFD/tools/add_configuration.py acorn "Acorn controller board"
```

This adds `acorn` and `acorn_note` columns to `settings.csv` and a row to `configurations.csv`. Fill in that row by hand. Short names should describe the hardware or what's different about it, not a person, and be lowercase with underscores.

## The drive's own backup

The drive has one user backup slot, separate from these files:

- **P5.0.19 = 30** saves the current settings as the user backup.
- **P5.0.19 = 60** restores the user backup.
- **Never P5.0.19 = 9 or 19.** Those are factory resets.

The backup slot holds the **production** configuration, whichever setup is in service for members. It's what restores the machine at the end of a test session. When a new configuration goes into service, save it with P5.0.19 = 30 so the backup matches.

## Reading the drive's current settings

Setting **P0.0.01 = 2** (Check mode) makes the keypad list only parameters that differ from factory, shown with a `C` prefix instead of `P`. That's the quickest way to read a configuration off the drive. P0.0.01 itself appears in the list as `C0.0.01`. Set it back to `0` when done.

Check mode lists differences from *factory*, so it won't show `machine-type` parameters that happen to be at their factory value. Read the motor parameters (P0.0.14–P0.0.23), acceleration/deceleration times (P0.0.11, P0.0.12) and carrier frequency (P1.0.22) separately.

## Notes on the manual

The Chapter 5 tables have a few misprints that Chapter 6 corrects (option lists for P0.1.19, P0.1.25, P2.0.33 and P4.0.02, among others). `parameters.csv` uses the corrected versions and notes each one in its `note` column.

The `change` column in `parameters.csv` comes from the manual's ☆/★ marks: `any time` can be changed while the spindle runs, and `stopped` needs the spindle stopped.
