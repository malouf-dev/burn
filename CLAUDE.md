# Working in this repository

- Read docs/proposal.md first. Section 2 lists decisions; don't start work that depends on an Open one without asking.
- This branch (`main`) is the new Swift app. The old Objective-C Burn is on `master`, a reference for behaviour only.
- Licence is MIT. Never copy or translate code from Burn (GPL v2), libburn (GPL) or cdrecord (CDDL). Work from the MMC and ISO 9660 standards.
- No DiscRecording. Only `Packages/BurnKit/Sources/CIOKitMMC` and `IOKitTransport` may touch IOKit.
- Swift 6 language mode, complete concurrency checking, zero warnings.
- Cloud sessions run Linux without Swift or Xcode. CI on macOS is the build and test signal. Don't report a change as working until CI passes.
- Engine logic must be testable with the simulated drive in `MMCSimulator`. When a hardware test fails, add a simulator test that reproduces it before fixing.
- Hardware tests need the owner's Mac. Record results in docs/hardware-testing.md.
- Keep pull requests small, with one behaviour each.
