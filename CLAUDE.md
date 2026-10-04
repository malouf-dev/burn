# Working in this repository

- Read docs/proposal.md first. Section 2 lists decisions; don't start work that depends on an Open one without asking.
- Read docs/development-notes.md for what past sessions learned, especially about drives, USB timeouts and macOS holding discs.
- This branch (`main`) is the new Swift app. The old Objective-C Burn is on `legacy`, a reference for behaviour only.
- Licence is MIT. Never copy or translate code from Burn (GPL v2), libburn (GPL) or cdrecord (CDDL). Work from the MMC and ISO 9660 standards.
- No DiscRecording. Only `Packages/BurnKit/Sources/CIOKitMMC` and `IOKitTransport` may touch IOKit.
- Swift 6 language mode, complete concurrency checking, zero warnings.
- Cloud sessions run Linux without Swift or Xcode. CI on macOS is the build and test signal. Don't report a change as working until CI passes.
- Local sessions on the owner's Mac can build and test directly: `swift build` and `swift test --package-path Packages/BurnKit`, `scripts/run-app.sh` for the app, and `burnctl` against the drive. Run the tests before pushing, and still check CI.
- Ask for logs by full path, such as `--log ~/Desktop/burn.log`. The app writes a log for each run to `~/Library/Logs/Burn/` as it goes and keeps the last five, so a crash or hang still leaves one; the Log panel's Show Log Files button opens it.
- Engine logic must be testable with the simulated drive in `MMCSimulator`. When a hardware test fails, add a simulator test that reproduces it before fixing.
- Hardware tests need the owner's Mac. Record results in docs/hardware-testing.md.
- Commit to `main`. Keep each commit to one behaviour, and push only once CI would pass.
