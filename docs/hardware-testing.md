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
python3 scripts/compare-trees.py /path/to/TestData "/Volumes/TestData"
```

It compares every file's contents, and compares names in composed Unicode form, because macOS can report accented names decomposed.

## What to record

For each run: date, commit, macOS version, Mac model, drive vendor, model and firmware, connection, media brand and type, speed, result, duration, and the diagnostic log.

## Where things stand

On the Pioneer BD-RW BDR-UD04 (firmware 1.14, USB), as of 30 September 2026.

| Media | Burn and verify | Mounts in Finder, files match | Erase | Runs |
|---|---|---|---|---|
| CD-R | Passed | Passed | n/a | 6 |
| DVD-R | Passed | Passed | n/a | 4, 5 |
| DVD-RW | Passed with the immediate-bit fix | Passed | Untested on a good disc | 17 |
| BD-R | Not tested | Not tested | n/a | 3 read a closed disc only |
| DVD+R, DVD+R DL | Not tested: no media | Not tested | n/a | |
| CD-RW | Not tested | Not tested | Not tested | |
| DVD+RW, BD-RE | Not supported yet | | | |

Other findings:

- A DVD-RW's close takes about 7 minutes, and a small DVD-R's about 4. USB times out any one command after 240 s. Long commands go with the immediate bit and are polled (runs 7 and 17).
- Run 7's cut-off close left a TDK DVD-RW that this drive can't erase or format (runs 8 to 16). A failed burn now keeps the drive and erases or ejects the disc before macOS reads it.
- Taking the drive while it is empty, then inserting the disc, stops macOS from reading a disc it would get stuck on (run 10).
- Not yet seen on hardware: a failed burn going through the keep-the-drive path, the app itself.

## Results

| Run | Date | Commit | Drive | Media | Operation | Result | Notes |
|---|---|---|---|---|---|---|---|
| 1 | 2026-09-29 | `0eaf0d8` | 1 drive found (model not yet known) | none | `burnctl list`, `burnctl status` | Failed: drive found, but opening it returned 0xFFFFFFFD (couldn't create the drive interface) | Open code didn't say which IOKit step failed. Added per-step errors, fallbacks and `burnctl diagnose`. Simulator can't reproduce IOKit plug-in failures, so no simulator test. |
| 2 | 2026-09-29 | `f3c5bed` | USB Blu-ray burner (IOBDServices) | not recorded | `burnctl diagnose`, `burnctl status` | Failed: MMC interface created, but TEST UNIT READY returned 0x10000003 (Mach: invalid destination) and no SCSI task interface | The C wrapper destroyed the IOKit plug-in straight after taking the interface, which closes the connection to the kernel. Plug-ins now live until the drive is closed. Direct SCSI task interface returns 0xE00002C7 (unsupported), as expected for burners. |
| 3 | 2026-09-29 | `a02d4aa` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | BD-R (already written) | `burnctl diagnose`, `burnctl status` | Passed: MMC and SCSI task interfaces open, TEST UNIT READY good, exclusive access available. Status read the disc as a closed BD-R. | First run where the drive answers commands. Whether the disc really was closed still needs confirming. |
| 4 | 2026-09-29 | `ff85139` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | DVD-R, blank | `burnctl status`, then `burnctl burn ~/burn-test --log burn.log` (one 6-byte file, 178-block image) | Passed: status read "blank DVD-R, 4.71 GB free". Written (disc at once) and every block verified. 243 seconds in total. | First real burn. Still to check: the disc mounts in Finder with hello.txt intact, and where the 243 seconds went (see burn.log). |
| 5 | 2026-09-29 | `b048a9b` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | DVD-R from run 4 | Mounted in Finder, compared with `compare-trees.py` | Contents correct, but at `burn-test/hello.txt` rather than the root. burn.log: writes and read-back took seconds; SYNCHRONIZE CACHE took 236 s while the drive closed the disc at once, which is expected for a small DVD-R. | `burnctl` now puts a single folder's contents at the root. The log's repeated-transfer summary now keeps time order and totals its duration. |
| 6 | 2026-09-29 | `7cef579` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | CD-R, blank | `burnctl status`, `burnctl burn ~/burn-test --log burn.log` (176-block image) | Passed: "blank CD-R, 737 MB free". Track at once written, track and session closed, every block verified, 77 seconds. | First CD-R. The Finder comparison (`scripts/compare-trees.py`) matched, checked after run 17. |
| 7 | 2026-09-29 | `7cef579` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | DVD-RW, blank | `burnctl status`, `burnctl burn ~/burn-test --log burn.log` | Failed: writes fine, then SYNCHRONIZE CACHE returned after 242 s with status 02h and empty sense. The display sat at "Closing 100%" with no progress. | Status 02h with no sense is IOKit's "protocol timeout": the USB transport gave up on one long command. Run 4's DVD-R finished just inside the limit at 236 s. Long commands now use the immediate bit and poll TEST UNIT READY, showing the drive's progress. Simulator now times out long commands sent without it. |
| 8 | 2026-09-29 | `dbb0806` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | DVD-RW from run 7 | `burnctl status`, `burnctl eject`, `burnctl erase` | Failed: status showed "DVD-RW with data on it", so the close had finished. Eject gave 0xE00002E2 (not permitted). Erase couldn't take exclusive access: 0xE00002D5 (busy). | macOS had the disc. burnctl never unmounted before taking the drive. Burning, erasing and ejecting now unmount through Disk Arbitration first. Simulator tests cover eject and erase of a mounted disc. |
| 9 | 2026-09-30 | `16e0d5b` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | DVD-RW from run 7, ejected and reinserted | `burnctl status`, `drutil eject`, `drutil erase quick`, `ps`, `diskutil list external`, `ioreg` | Failed: the drive spun up and stopped over and over. The eject button and `drutil` could not get the disc. `status` reported the disc closed. `ioreg` showed IODVDMedia of 360,448 bytes (176 blocks, as written) with no BSD disk, and the storage driver and media busy for 345 s: macOS was stuck reading the disc. Music and Finder held SCSITaskUserClient connections, as they do on any Mac with a burner. | The close finished, so the data blocks probably don't read back after run 7's timeout. Not yet confirmed. burnctl erase and inspect can now take the drive while it is empty, so macOS never reads the next disc. `inspect` then reads blocks 0, 16 and the last block to confirm the cause. |
| 10 | 2026-09-30 | `7c1e113` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | DVD-RW from run 7 | `burnctl inspect --log inspect.log` with the drive empty, disc inserted when asked | Passed as a diagnosis: exclusive access was taken on the empty drive, and macOS never touched the disc once it went in. Disc information, track information and READ CAPACITY (last block 175) all answered at once. READ of blocks 0, 16 and 175 each failed after about 7 s with MEDIUM ERROR 03/11/05 (L-EC uncorrectable). | Confirms run 9: the disc's layout was recorded but its data doesn't read back. macOS's reads of block 0 each take about 7 s and fail, which is the stuck loop. Next: erase with the drive taken first, then burn again with the immediate-bit fix. If that burn verifies, run 7's interrupted flush was the cause. If it fails the same way, suspect the disc or DVD-RW writing. |
| 11 | 2026-09-30 | `1393ffe` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | DVD-RW from run 7 | `burnctl erase` with the drive empty, then `burnctl burn ~/burn-test` | Partial: burnctl took the empty drive and macOS never touched the disc. The quick erase ran to 100%, then TEST UNIT READY returned MEDIUM ERROR 03/51/00 (erase failure). After that the disc appeared in macOS, but `status` showed "DVD-RW with an unfinished burn" and burn refused it. | A quick erase only clears the lead-in, and the drive reported that as failed. erase now falls back to a full erase. A burn that fails after changing the disc now keeps the drive and erases (rewritable) or ejects (write-once) the disc before macOS sees it. |
| 12 | 2026-09-30 | `122fcb6` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | DVD-RW from run 7 | `burnctl erase` (disc already in), then `burnctl inspect` | Failed: the quick erase stopped at 76.2% with HARDWARE ERROR 04/44/8D (ASCQ 8Dh is vendor-specific). The full-erase fallback didn't run, since it only covers 03/51/00. Finder then showed the disc as "Untitled DVD", twice. `inspect`: status appendable, last session incomplete, track 1 blank from 0 with 2,297,888 blocks free and no valid next writable address, capacity last block 0. READ of blocks 0 and 16 failed at once with 03/51/01, incomplete erase operation detected. | The drive records the erase as started and not finished, and won't write until one completes. Two quick erases of this disc have now failed with different errors, which points at the disc or the drive with this disc. Next: `burnctl erase --full`, and `drutil erase full` to compare if that fails. |
| 13 | 2026-09-30 | `54afa54` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | DVD-RW from run 7 | `burnctl erase --full --log ~/Desktop/erase-full.log` | Failed: BLANK (full, immediate) was accepted. The drive reported "operation in progress" for 35 s, then MEDIUM ERROR 03/51/00, erase failure. The quick erase in run 12 had failed after 28 s with 04/44/8D. Finder now shows three "Untitled DVD" icons, one more each time burnctl gives the drive back. | A full erase of a DVD-RW takes many minutes, so the drive gave up early. Every operation that writes to this disc now fails within about 30 s. That points at the drive being unable to write this disc, which may also explain run 7's unreadable data. To confirm: `drutil erase full` on this disc, and a different DVD-RW with burnctl. The log now includes the drive's progress. |
| 14 | 2026-09-30 | `e38a04d` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | TDK DVD-RW from run 7 | `drutil erase full`, then `burnctl inspect --log ~/Desktop/inspect-after-drutil.log` | Failed: drutil printed "Erase completed", but the disc was unchanged. Last session incomplete, and READ of blocks 0 and 16 still failed with 03/51/01, incomplete erase. Finder then refused to burn an "Untitled DVD" as read-only (0x80020042). | Neither burnctl nor drutil can erase this disc in this drive. Run 7's cut-off close most likely damaged the disc's recording management area: our bug, on a good TDK disc. Next: `burnctl format`, a full format (type 10h) using the descriptor the drive offers, as a different route through the drive. |
| 15 | 2026-09-30 | `4cf4964` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | TDK DVD-RW from run 7 | `burnctl format --log ~/Desktop/format.log` | Failed: the drive offered formats 00h, 10h and 15h. FORMAT UNIT 10h with the immediate bit was accepted, and progress climbed steadily at about 0.11% a second, so the drive really was writing. At 13.8%, after 124 s, TEST UNIT READY returned MEDIUM ERROR 03/31/01, format command failed. | 13.8% of the disc is about 317,000 blocks, or 650 MB. At 2x DVD speed that is about 235 s of writing, close to the 242 s run 7's flush ran before USB cut it off. So the format may be failing exactly where run 7's padding write stopped. That fits, but it isn't proven, since the write speed in run 7 is unknown. Next: `burnctl format --quick` (type 15h). |
| 16 | 2026-09-30 | `6b4ea6a` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | TDK DVD-RW from run 7 | `burnctl format --quick --log ~/Desktop/format-quick.log` | Failed: the quick format (type 15h) reached 5.7%, then MEDIUM ERROR 03/31/01, format command failed. | Every way this drive can rewrite the disc has now failed: quick and full blank (burnctl), full blank (drutil), full and quick format. Most likely run 7's cut-off write left an area this drive can't write over. The disc may still recover in another drive. The fix for the cause (immediate bit and polling) is still to be proven on hardware. |
| 17 | 2026-09-30 | `39c07c9` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | New DVD-RW, blank | `burnctl inspect`, then `burnctl burn ~/burn-test --log ~/Desktop/burn-dvdrw.log` (176-block image) | Passed: written, closed and every block verified. SYNCHRONIZE CACHE went with the immediate bit and returned at once. The drive then reported progress from 0% to 100% over 233 s, stayed busy at 100% for another 203 s, and was ready after 436 s in all. Verify read all 176 blocks. | Confirms the fix for run 7. The close takes 7 min 16 s, far past USB's 240 s limit. Run 7's plain command was cut off at 242 s, just as the drive reached 100% and began the final step, which likely writes the disc's management area. That fits the damage seen in runs 8 to 16. burnctl now shows elapsed time while closing, and "finishing up" once progress reaches 100%. The Finder comparison matched. |
| 18 | 2026-10-04 | `b986a15` | Pioneer BD-RW BDR-UD04, firmware 1.14, USB | BD-R, blank | The app (Debug build), real files, UDF bridge, checksums and 10% recovery data: 10,905,901 blocks, about 22 GB | Failed verification, but the disc reads. Recovery data seems to have taken about an hour (05:58 to 06:58 in the log), in a Debug build. Writing took 24 min, with two stalls of 25.6 s and 9.4 s. Closing took 12 s. Verify read about 95% of the disc, then reported a mismatch at image block 10,328,384, with no read error. The app ejected the disc, as it does for write-once media after a failed burn. The owner says the disc mounts and works, with no check run yet. The name "Better Off Ted (Season 1 & 2)" came out as "Better Off Ted (". | The mismatch block lies, by size, in `.burn/recovery.vol…par2`, near the end of the image; that's an estimate, since the log didn't say. The log now names the part of the image and shows how the block differs. Next: Verify's Check Files on this disc, and `par2 verify` on its recovery data, to tell whether the disc or the image read differed. The run script now builds Release, and the app allows 63-character names. Checked afterwards: Verify's Check Files found all 30 files match, and `par2 verify` loaded all 98 recovery blocks and found every file correct. So the disc holds the right bytes, recovery data included, and the mismatch came from the verify side: either the drive misread without an error, or the image served different bytes during verify. Image reads now continue past a short read and refuse to pad recovery data with zeros. Neither cause is proven yet. |
