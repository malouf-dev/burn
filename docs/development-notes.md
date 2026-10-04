# Development notes

A record of how the new Burn was built, why it's built the way it is, and what we learned along the way. Read it with `docs/proposal.md` (the plan and decisions) and `docs/hardware-testing.md` (every run on real hardware).

## Session 1: 29 and 30 September 2026

One long session, from an empty branch to a working app, done in a cloud session, with the owner testing on a Mac with a Pioneer BD-RW BDR-UD04 over USB. About 50 commits.

### What was built

- **BurnKit**, a Swift package:
  - `MMC`: SCSI and MMC commands, response parsers and the drive engine (`DiscDrive`, an actor).
  - `MMCSimulator`: a simulated drive for tests.
  - `ISOBuilder`: ISO 9660 and Joliet images, the `.burn` checksum folder and the checksum verifier.
  - `CIOKitMMC` and `IOKitTransport`: the only code that touches IOKit.
  - `burnctl`: a command-line tool for testing the engine on hardware.
- **The app**: one window with Burn and Verify views, a burn sheet, a file table, and a log panel.
- **CI** on GitHub's macOS runners:
  - builds and tests with warnings as errors, and builds the app
  - mounts a test image with `hdiutil` and compares it file by file
  - checks the image's checksums with plain `shasum`
  - runs simulated burns

### Why it's built this way

These are the main decisions. Section 2 of the proposal holds the full list.

- **A new app, not a port (D1).** Burn's code is Objective-C built on DiscRecording. Porting it would have carried both forward. Starting on an orphan `main` branch let the new app be a departure, with Burn kept on `legacy` for reference.
- **Our own engine over IOKit, no DiscRecording (D10).** Apple has been letting DiscRecording fade. The public IOKit MMC and SCSI task interfaces are lower level, still supported, and let the app talk to drives directly. The cost is writing the burning logic ourselves. The payoff showed up in this session: every failure could be traced to a specific command and fixed.
- **MIT licence (D5).** That rules out copying or translating code from Burn (GPL), libburn (GPL) or cdrecord (CDDL). Everything was written from the MMC, ECMA-119 and ECMA-167 standards and from what the drive did.
- **ISO 9660 with Joliet now, UDF next (D11).** It's readable everywhere and small to write. Its limits are 4 GB per file and 103-character names. The app blocks files that are too large, with a clear message. UDF is planned in section 9.8 of the proposal.
- **A hidden `.burn` folder with checksums on every disc (D12).** It holds one SHA-256 per file, in the form `shasum -a 256 -c` reads. A disc can be checked years from now with no special software. `info.json` alongside adds the disc name, date and app. This is per file, not per folder, so a check names exactly what was lost.
- **Data discs only for now (D13).** Audio, video and copy can come later, on the same engine.
- **Simulator first.** Cloud sessions have no drive and no Swift. The simulated drive lets every engine change be tested in CI. Whenever hardware showed a new behaviour, it was taught to the simulator in a test first.

### What went wrong, and what we learned

In the order it happened. The run numbers match `docs/hardware-testing.md`.

1. **IOKit plug-ins must stay alive (runs 1 and 2).** The first build released the IOKit plug-in right after taking its interfaces. Releasing it closes the connection to the drive, so every command failed with `0x10000003`. Fix: keep the plug-in until the device is closed. `burnctl diagnose` was added here, so the next unexplained failure could be traced step by step.

2. **USB times out any command after about 240 seconds (run 7).** Closing a small DVD-R took 236 s (run 4), just under the limit. Closing a DVD-RW took longer, and the plain SYNCHRONIZE CACHE was cut off at 242 s. IOKit then reports status 02h with empty sense, which looks like a drive error but is really a protocol timeout. Fixes:
   - Long commands (flush, close, finalise, erase, format) now go with the immediate bit, and TEST UNIT READY is polled every second. The drive reports progress while it works.
   - A long command is never retried without the immediate bit.
   - The C wrapper reads the task's service response, so a transport failure reads as one.

   Run 17 proved it: the DVD-RW close took 7 min 16 s and verified.

3. **That timeout cost a good TDK DVD-RW (runs 7 to 16).** The cut-off close left a disc whose data doesn't read back and whose record-keeping area this drive can't repair. Nothing could fix it:
   - quick and full erase, from burnctl and from `drutil`
   - full and quick format

   Every attempt failed at or near the same spot on the disc, most likely where run 7's write stopped. Lesson: a bug in the close can damage a disc for good, so test new close logic on spare discs.

4. **macOS can get stuck reading a bad disc and hold the drive (runs 8 to 10).** With the damaged disc in the drive, macOS's storage driver spent minutes retrying reads. Nothing could take the drive or eject the disc, and only unplugging the drive cleared it. What we found:
   - `ioreg` showed exactly what was going on: the media object busy, and which processes held the drive. Music and Finder always hold a connection; that's normal.
   - Taking the drive while it's empty, then inserting the disc, stops macOS from ever reading that disc. `burnctl inspect` and `erase` do this when the drive is empty.
   - A burn that fails after writing now keeps the drive. It erases a rewritable disc, or ejects a write-once one, before macOS sees it.

5. **macOS must let go of a disc before we can take the drive (run 8).** Taking exclusive access fails while a disc is mounted, and eject through the shared interface is refused. Fix: unmount through Disk Arbitration first, and retry for a while if the drive is still busy.

6. **macOS locks the tray, and the lock outlasts the unmount.** The first eject from the app failed with 05/53/02, medium removal prevented. Fix: send PREVENT ALLOW MEDIUM REMOVAL to unlock the tray before ejecting.

7. **Status must say what the drive actually reports.** "Disc with data" hid the difference between a closed disc, a half-finished burn and an unfinished erase. Status now reads the last session's state. `burnctl inspect` shows the drive's full view, including test reads of key blocks.

8. **Names on a mounted disc come back decomposed (CI).** macOS lists a disc's accented names decomposed (NFD), while Joliet stores them composed (NFC). The comparison script and the verifier compare names in NFC. CI proves `shasum -c` still finds the files.

9. **Small Swift traps, all caught by CI:**
   - `FileHandle.read(upToCount:)` returns nil at the end of a file, not empty data.
   - Swift treats `"\r\n"` as one character, so splitting on `"\n"` misses it.
   - `SCSITaskInterface`'s member is `GetSCSIServiceResponse`. The name was checked against Apple's header after the first guess broke the build.
   - Public structs need explicit public initialisers for the app to use them.
   - The app build log was cut to its last 40 lines, which hid the errors. CI now prints every `error:` line first.

### How we worked, and what to keep doing

- **Hardware tests need precise instructions.** The best runs came from exact commands with a `--log ~/Desktop/<name>.log` path, then reading the log line by line. Screenshots alone were often not enough.
- **Say what's known and what's inferred.** Twice I stated a cause the next run disproved: that the DVD-RW close had finished, and that `drutil` had recovered the disc. Both times the drive's own answers corrected it. Check with the drive before concluding.
- **Push only once CI would pass, and keep one behaviour per commit.** CI caught every compile error the cloud session couldn't. The one-behaviour rule slipped a few times, where changes shared a file; those commits say so.
- **Keep the hardware log up to date as you go.** `docs/hardware-testing.md` has every run, including the failures. That record made the run 7 to 16 diagnosis possible.

## Session 2: 4 October 2026

A cloud session. The owner asked for Blu-ray data discs in the best format, with full checksums, and for recovery data so a damaged disc can be repaired.

### Decisions

- **UDF 2.01 bridge on every disc (D14).** UDF is what Blu-ray expects, holds files of any size and keeps real names up to 255 bytes. ISO 9660 and Joliet stay alongside, sharing the file data, so older systems still read the disc. One format for CD, DVD and Blu-ray keeps testing simple. UDF 2.01 rather than 2.50 or 2.60: those add a metadata partition that matters for rewriting in place, which closed discs don't need, and 2.01 is read by every current system.
- **PAR2 recovery data in `.burn/` by default, 10% (D15).** Checksums say what was lost; recovery data puts it back. PAR2 is an open format, so any PAR2 tool can repair a disc without Burn. We write our own encoder from the PAR2 2.0 specification, since par2cmdline is GPL.

### What was built

- The UDF bridge (proposal 9.8). Checksum paths follow UDF names, since every current system reads UDF first.
- Images made on demand. `DiscImage` serves any block from the layout and the source files, so a burn needs no image file. CI's simulated BD-R burn writes and verifies straight from it.
- PAR2 recovery data and repair (proposal 9.9), with Repair in Verify and `burnctl repair`.
- The app no longer blocks files of 4 GB or more, and its size estimate counts a block per file for its UDF entry.
- A fix for a hang: two Joliet names that shortened to the same 103 characters made the builder loop forever, because the duplicate suffix was cut off with the rest.

### What we learned

- **macOS mounts a bridge image as UDF**, so CI checks `mount` for `udf`, and mounts a `--no-udf` image to keep testing ISO 9660 through macOS.
- **The UDF code passed on the first CI run.** Writing the test reader separately from the builder, both from ECMA-167 and the UDF 2.01 text, caught nothing, which means either both are right or both share a misreading. macOS mounting the image and reading a 4.3 GB file correctly is the stronger evidence.
- **This cloud session can't download CI artifacts or logs.** The built-in `gh` only talks to api.github.com, and artifacts come from another host. CI now puts failing test lines, par2's output on failure, and timings into annotations, which the API returns. Checking an image with Linux tools such as `udfinfo` needs a local session.
- **PAR2 also passed par2cmdline on the first run**, both ways. The one bug was ours alone: the packet reader dropped each recovery slice's exponent along with its data. The repair test caught it.
- **Plain Swift was too slow for recovery data.** 256 MB took 90 to 160 seconds on CI. A C kernel with NEON table lookups brought it to 27. It was tested here first, under an ARM emulator, against a plain multiply.
- **Keep a log on disk from the start.** The app kept its log only in memory, so when it stopped during a test there was nothing to read, and macOS had saved no crash report. Each run now writes `~/Library/Logs/Burn/Burn <date>.log` line by line, with standard error, and keeps the last five.
- **Watch for names that hide the method you mean.** `let handle = try handle(for: node)` doesn't compile in Swift; the new constant shadows the method. Use `self.handle(for:)`.

## Open items

- **Hardware still untested:** DVD+R (no media on hand), BD-R, CD-RW erase, a failed burn going through the keep-the-drive path, and a burn from the app itself.
- **UDF on a burned disc:** a BD-R, and a CD-R or DVD-R, should be burned and read on macOS, and ideally Windows, before relying on it.
- **Recovery data on hardware:** time it on the owner's Mac, burn a disc with it, and repair a deliberately damaged copy.
- **More than 32,768 files** get no recovery data yet; several recovery sets would fix it.
- **Name and bundle identifier (D6):** see below.

### Naming the project (D6)

The app stays **Burn**. The repository needs a more descriptive name, and the bundle identifier should follow from it. It is `com.example.burn` for now.

| Option | For | Against |
|---|---|---|
| `burn-macos` (recommended) | Says what it is: Burn for the Mac. Keeps Burn first. Doesn't tie the name to a language if parts change later. | Doesn't mark it as the rewrite. |
| `burn-swift` | Marks it as the Swift rewrite, apart from the original Burn. Sorts next to `burn`. | The language is an implementation detail and may date. |
| `swift-burn` | Common style for Swift projects. | Puts the language before the app's name. |

Renaming the repository on GitHub keeps the old URLs redirecting, and the `legacy` branch comes along unchanged. When a name is chosen, close D6 in the proposal, and set the bundle identifier and the README to match.
