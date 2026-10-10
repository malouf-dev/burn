# Working in this repository

- Read docs/proposal.md first. Section 2 lists decisions; don't start work that depends on an Open one without asking.
- Read docs/development-notes.md for what past sessions learned, especially about drives, USB timeouts and macOS holding discs.
- `main` and `development` hold the new Swift app. The old Objective-C Burn is on `legacy`, a reference for behaviour only.
- Licence is MIT. Never copy or translate code from Burn (GPL v2), libburn (GPL) or cdrecord (CDDL). Work from the MMC and ISO 9660 standards.
- No DiscRecording. Only `Packages/BurnKit/Sources/CIOKitMMC` and `IOKitTransport` may touch IOKit.
- Swift 6 language mode, complete concurrency checking, zero warnings.

## Building and checking

Everything runs on the owner's Mac. There is no CI.

- `scripts/check.sh --quick` builds the package and the app with warnings as errors and runs every test. Use it while working.
- `scripts/check.sh` is the full check, about 5 minutes. It adds a build from a fresh copy of the last commit, and puts disc images, checksums and recovery data through macOS's own tools and `par2`. Run it before every push and report its result.
- `scripts/run-app.sh` builds the app and opens it. The owner runs it; end a report of a build with it, in a `bash` block.
- `burnctl` is the command-line tool for testing the engine against the drive. The owner uses the app, not `burnctl`.

## Files and the Mac

- Write only inside this folder. Scratch files go in `scratch/`, which git ignores. Everywhere else on the Mac is read-only unless the owner approves a write.
- The owner's real data is off limits for testing: the NAS shares under `/Volumes`, the files being burned, and the app's saved disc set. Use fixtures or copies in `scratch/`.
- The app writes a log for each run to `~/Library/Logs/Burn/` as it goes and keeps the last five. Read logs there by path; never ask the owner to paste one. They can be hundreds of MB, so search them rather than reading them whole.
- The disc set in progress is saved in `~/Library/Application Support/Burn/Disc set.json`.

## Tests and hardware

- Engine logic must be testable with the simulated drive in `MMCSimulator`. When a hardware test fails, add a simulator test that reproduces it before fixing.
- Hardware tests need the owner's Mac, the drive and blank discs. Blanks are expensive, so never risk one on an untested change to closing or erasing; try it on a rewritable or cheap disc first. Record every run in docs/hardware-testing.md.
- Every step of a burn retries five more times, then holds and asks the owner. Never fail a disc at the first error, and never skip past a stretch the drive couldn't write. Section 5.4 of the proposal describes this.

## Git

- Work on the `development` branch. Keep each commit to one behaviour.
- Commit only after the owner has seen the change and said so. Push only once `scripts/check.sh` passes.
- Fast-forward `main` to `development` when the owner says so, usually after a hardware test.
