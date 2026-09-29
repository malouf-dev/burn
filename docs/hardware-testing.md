# Hardware testing

Hardware tests need a Mac, a disc drive and blank media. Run them from a Claude Code session on the Mac, or by hand with `burnctl`.

## Before a session

- Build: `swift build --package-path Packages/BurnKit`
- List drives: `swift run --package-path Packages/BurnKit burnctl list`
- Check the disc: `swift run --package-path Packages/BurnKit burnctl status`

Slim USB drives can be short of power, especially on laptops. Power problems look like drive errors. Use a drive with its own power supply, or both USB plugs if it has two.

## Test data

One folder containing:

- small text files
- one 1 GB file of random data (leave it out for CDs)
- a folder tree five levels deep
- names with spaces, accents and emoji
- one name of 100 characters

## Comparing a burned disc with its source

```sh
python3 scripts/compare-trees.py /path/to/TestData "/Volumes/DiscName/TestData"
```

It compares every file's contents, and compares names in composed Unicode form, because macOS can report accented names decomposed.

## What to record

For each run: date, commit, macOS version, Mac model, drive vendor, model and firmware, connection, media brand and type, speed, result, duration, and the diagnostic log.

## Results

| Run | Date | Commit | Drive | Media | Operation | Result | Notes |
|---|---|---|---|---|---|---|---|
| 1 | 2026-09-29 | `0eaf0d8` | 1 drive found (model not yet known) | none | `burnctl list`, `burnctl status` | Failed: drive found, but opening it returned 0xFFFFFFFD (couldn't create the drive interface) | Open code didn't say which IOKit step failed. Added per-step errors, fallbacks and `burnctl diagnose`. Simulator can't reproduce IOKit plug-in failures, so no simulator test. |
| 2 | 2026-09-29 | `f3c5bed` | USB Blu-ray burner (IOBDServices) | not recorded | `burnctl diagnose`, `burnctl status` | Failed: MMC interface created, but TEST UNIT READY returned 0x10000003 (Mach: invalid destination) and no SCSI task interface | The C wrapper destroyed the IOKit plug-in straight after taking the interface, which closes the connection to the kernel. Plug-ins now live until the drive is closed. Direct SCSI task interface returns 0xE00002C7 (unsupported), as expected for burners. |
