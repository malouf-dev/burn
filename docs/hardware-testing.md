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
#!/bin/sh
# Usage: compare.sh /path/to/TestData "/Volumes/DiscName"
src="$1"; disc="$2"
( cd "$src"  && find . -type f ! -name '.DS_Store' -print0 | sort -z | xargs -0 shasum -a 256 ) > /tmp/source.sha256
( cd "$disc" && find . -type f ! -name '.DS_Store' -print0 | sort -z | xargs -0 shasum -a 256 ) > /tmp/disc.sha256
diff /tmp/source.sha256 /tmp/disc.sha256 && echo "Match"
```

## What to record

For each run: date, commit, macOS version, Mac model, drive vendor, model and firmware, connection, media brand and type, speed, result, duration, and the diagnostic log.

## Results

| Run | Date | Commit | Drive | Media | Operation | Result | Notes |
|---|---|---|---|---|---|---|---|
