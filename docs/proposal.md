# Burn (new app): proposal and 0.1 plan

- **Status:** Active plan
- **Updated:** 29 September 2026
- **Working name:** Burn. The final name is still open (D6).

## How to use this document

This is the plan for the new app on the `main` branch of `malouf-dev/burn`. It is written for the owner and for any Claude Code session working here.

- Section 2 lists decisions. Items marked **Open** need the owner's answer before the step that depends on them.
- The old Objective-C app lives on the `legacy` branch of the same repository. It is a reference for behaviour only (see D5).

## Contents

1. Summary
2. Decisions
3. Background: Burn
4. The platform in September 2026
5. The disc engine
6. Product direction
7. Engineering rules
8. Architecture
9. Milestone 0.1 alpha
10. Repository, CI and testing
11. Roadmap after 0.1
12. Risks and unknowns
13. Reference map of Burn's source
14. Format notes from Burn
15. Sources

## 1. Summary

We are building a new disc-burning app for macOS in Swift. It learns from Burn, an Objective-C app last updated in 2021, but it is a new product with its own design and code.

The app does not use Apple's DiscRecording framework. Apple is retiring its optical-disc frameworks: it removed DVDPlayback from the macOS 27 SDK, and DiscRecording's documentation is gone from its developer site. Instead the app has its own burning engine. It talks to drives with MMC, the standard command set every CD, DVD and Blu-ray drive understands, through IOKit's SCSI interfaces.

The first milestone, 0.1 alpha, is an app that opens, sees a disc, and writes files to it with verification.

## 2. Decisions

| ID | Decision | Status |
|---|---|---|
| D1 | New code on an orphan `main` branch in `malouf-dev/burn`. Burn stays on `legacy` as a reference. | Decided |
| D2 | 0.1 alpha goal: the app opens, sees a disc, and writes files to it with verification. | Decided |
| D3 | Swift 6 language mode. SwiftUI first, AppKit only where SwiftUI falls short. | Decided |
| D4 | Minimum macOS follows a rolling policy: the current version and the two before it. Today that means macOS 15. | Decided |
| D5 | Licence: MIT. Burn (GPL v2), libburn (GPL) and cdrecord (CDDL) are references for behaviour only. None of their code is copied or translated. | Decided |
| D6 | Final app name and bundle identifier. The working name is Burn and the placeholder bundle ID is `com.example.burn`. | Open |
| D7 | Distribution: Developer ID signing, notarisation and Sparkle 2 updates. Not needed for 0.1. | Proposed |
| D8 | Drop VCD, SVCD, DivX and DVD-Audio. Keep data discs, audio CD, disc images, disc copy and DVD-Video. | Proposed |
| D9 | No App Sandbox. The engine opens IOKit device interfaces, which the sandbox blocks. | Proposed, confirm on hardware |
| D10 | Our own engine over IOKit's MMC interfaces. No DiscRecording. | Decided |
| D11 | 0.1 disc format: ISO 9660 with Joliet, built by our own code. UDF comes in 0.2. | Proposed |

## 3. Background: Burn

Burn is a free macOS app by Maarten Foukhar (Kiwi Fruitware), licensed GPL v2. Its code is on the `legacy` branch here, copied from https://sourceforge.net/p/burn-osx/code-git/ci/master/tree/ at commit `f39366b` (17 January 2021). It burns data discs, audio CDs, MP3 discs, DVD-Video with menus, VCD, SVCD, DivX discs, DVD-Audio and disc images, and it copies discs.

- About 22,700 lines of Objective-C, plus 10 XIB files. 13 languages.
- Deployment target macOS 10.9. No tests and no CI.
- It can't be built with the macOS 26 SDK or later, because it imports Carbon.
- All disc work goes through DiscRecording, including a private class (`DRCallbackDevice`) for saving images.
- Six GPL command-line tools are committed as binaries (ffmpeg, mkisofs, dvdauthor, spumux, vcdimager, dvda-author).
- The released app logs every tool command and DiscRecording status when its debug setting is on: `defaults write com.kiwifruitware.Burn KWDebug -bool YES`.

Problems in Burn that the new app must not repeat:

| Problem | Where in Burn | Do instead |
|---|---|---|
| It can crash with no drive connected: it takes the first item of an empty list. | `KWBurner.m:875`, `KWCommonMethods.m:878` | Treat "no drive" as a normal state. |
| Drives are identified by product name. Two identical drives collide. | `KWCommonMethods.m:867` | Use the IORegistry entry ID. |
| A disc that can't be written is ejected without asking. | `KWBurner.m:436` | Say why, and let the user eject it. |
| Blu-ray speeds are divided by the DVD 1x speed. | `KWBurner.m:827` | Use the 1x rate for the media class. |
| A custom filesystem mix uses a logical OR, so it collapses to ISO 9660 only. | `KWDataController.m:356` | Test every combination. |
| Verification is off by default. | `KWApplication.m:31` | Always verify. |
| ffmpeg output is parsed from log text. | `KWConverter.m:764` | Use structured output. |

## 4. The platform in September 2026

From Apple's release notes, except the last two points. Links are in section 15.

- macOS 27 is current. Xcode 27 includes Swift 6.4 and runs only on Apple silicon Macs with macOS Tahoe 26.6 or later.
- Apple removed the DVDPlayback framework from the macOS 27 SDK, and will remove it from macOS later.
- DiscRecording isn't mentioned in the release notes, but its documentation pages return "not found".
- IOKit's `MMCDeviceInterface` and `SCSITaskDeviceInterface` are still documented, with no deprecation. Apple made them available to Mac Catalyst apps in 2025.
- DriverKit's SCSIPeripheralsDriverKit (macOS 13 and later) has `IOUserSCSIPeripheralDeviceType05`, an official driver class for optical drives that can send MMC commands.
- Carbon is no longer in the SDK, as of macOS 26.
- Intel-based software will not run on macOS 28. The macOS 27 SDK still builds universal apps for macOS 12 and later.
- Not from Apple: a third-party report says `hdiutil` is deprecated in macOS 27. Unverified.
- From Apple's WWDC 2025 material: standard controls take on the Liquid Glass design when an app is built with the new SDK.

## 5. The disc engine

### 5.1 Layers

```
App (SwiftUI)
  └─ Engine: drive status, write, verify, erase           Swift, ours
       ├─ Disc image builder: ISO 9660 + Joliet           Swift, ours
       └─ MMC commands and parsers                        Swift, ours
            └─ Transport (one small module)
                 ├─ IOKit MMCDeviceInterface / SCSITask   today
                 ├─ DriverKit type 05 driver              fallback if Apple removes the IOKit path
                 └─ Simulated drive                       tests and CI
```

Everything above the transport is plain Swift. It builds and tests on any platform.

### 5.2 How the IOKit transport works

- Drives are found by matching IORegistry services whose `SCSITaskDeviceCategory` is `SCSITaskAuthoringDevice`.
- `MMCDeviceInterface` sends common read-only commands without taking over the drive: INQUIRY, TEST UNIT READY, GET CONFIGURATION, READ DISC INFORMATION, READ TRACK INFORMATION, and tray state.
- To write, the app calls `ObtainExclusiveAccess` on the `SCSITaskDeviceInterface`. The app then becomes the drive's driver until it releases access, and can send any command. This fails while a disc is mounted, so a mounted disc must be unmounted first.
- A small C file wraps these COM-style interfaces. Swift calls four or five plain C functions.

### 5.3 Why not an existing engine

- libburn and xorriso are actively maintained, but they don't drive real burners on macOS.
- cdrecord (schilytools) does burn on macOS through IOKit. It is CDDL-licensed C, community maintained, and last released in March 2024. We use it only as a reference.
- DiscRecording is what we are moving away from.

### 5.4 Write methods in 0.1

| Media | Method |
|---|---|
| CD-R, CD-RW | Track-at-once, Mode 1 data. Write parameters page (05h) set with MODE SELECT. |
| DVD-R, DVD-RW (sequential) | Disc-at-once: RESERVE TRACK for the full size, then write. |
| DVD+R, DVD+R DL | Sequential write, then CLOSE TRACK and close the session or finalise the disc. |
| BD-R | Sequential write (SRM), then CLOSE TRACK and close the session. |
| CD-RW, DVD-RW with data | Quick BLANK first, after the user confirms. |
| DVD+RW, BD-RE | Not in 0.1. They need formatting and overwriting, planned for 0.2. |

All writes use WRITE(10) in 2,048-byte blocks, followed by SYNCHRONIZE CACHE. Every method needs testing on real drives, and the table will change as we learn.

### 5.5 Verification

- While writing, the engine hashes every block range it sends (SHA-256 per 16 MiB, plus one for the whole image).
- After closing the disc, it reads every written block back with READ(10) and compares the hashes.
- The result says "Written and verified" only when every range matches.
- A later milestone adds a check of every file on the mounted disc.

## 6. Product direction

The new app is a departure from Burn.

- **The disc comes first.** The window opens on the drive and the disc in it.
- **One window.** No tabs and no floating inspector.
- **Safe by default.** Every burn is verified. Steps that can't be undone ask first.
- **Plain language.** For example, "Blank DVD+R, 4.7 GB free".
- **Nothing to set up for the common case.**
- **Keyboard and VoiceOver work from the first release.**

The visual design is open. 0.1 uses standard controls.

## 7. Engineering rules

1. **No DiscRecording, and public APIs only.** Only the transport module talks to IOKit.
2. **Swift 6 language mode with complete concurrency checking.** Zero warnings.
3. **Licence hygiene (D5).** Don't copy or translate code from Burn, libburn or cdrecord. Work from the MMC and ISO 9660 standards and from observed behaviour.
4. **Standard SwiftUI controls and SF Symbols.**
5. **Everything testable without hardware** except the transport. The simulated drive covers the engine in CI.
6. **Log every command.** Each operation writes the commands sent, the data sizes, the sense data and the timings to a diagnostic log.
7. **No binaries in git.** Helper tools, if any are added later, are built by CI from pinned sources.
8. **Few dependencies, all through Swift Package Manager.** 0.1 has none.
9. **A thin Xcode project.** Code lives in `Packages/BurnKit`.
10. **Rolling minimum macOS (D4).** Review each September.
11. **CI on every push**, plus a job against each year's Xcode beta.
12. **String Catalogs from the first string.**

## 8. Architecture

### 8.1 Repository layout

```
README.md, LICENSE, CLAUDE.md
docs/
  proposal.md                 this document
  hardware-testing.md         test protocol and results log
Packages/BurnKit/
  Package.swift
  Sources/
    MMC/                      commands, parsers, drive engine, transport protocol
    MMCSimulator/             simulated drive for tests
    ISOBuilder/               ISO 9660 + Joliet image builder
    CIOKitMMC/                C wrapper over IOKit's SCSI interfaces (macOS only)
    IOKitTransport/           Swift transport and drive discovery (macOS only)
    burnctl/                  command-line tool for hardware tests
  Tests/
Burn.xcodeproj, App/          SwiftUI app
.github/workflows/ci.yml
```

### 8.2 Concurrency

- Each drive is used by one actor at a time. Commands to a drive run one after another, off the main thread.
- The app observes drive state through an `@Observable` model on the main actor.
- Long operations report progress through `AsyncStream` and can be cancelled between commands.

## 9. Milestone 0.1 alpha

### 9.1 Goal

An app that opens, sees a disc, and writes files to it with verification.

### 9.2 Task order

1. Branch, docs, licence and CI. Done.
2. MMC commands and parsers with tests, and the simulated drive. Done.
3. The engine: drive status, write and verify, quick erase, against the simulated drive. Done.
4. The ISO 9660 + Joliet builder, tested by mounting its output in CI with `hdiutil`. Done.
5. The IOKit transport and `burnctl`. Written; untested on hardware.
6. The SwiftUI app: drive and disc state, adding files, burning with progress, results. First version done.
7. First hardware session on the owner's Mac: `burnctl list`, `burnctl status`, then a burn to CD-R and DVD+R.
8. Hardware test pass (section 10.3), fixes, then tag `v0.1.0-alpha`.

### 9.3 Media for 0.1

| Media | Needed for 0.1 |
|---|---|
| CD-R | Yes |
| CD-RW | Yes, for erase |
| DVD+R | Yes |
| DVD-R | Yes, if available |
| DVD+RW, DVD-RW | If available |
| BD-R, BD-RE | If a Blu-ray drive is available |

### 9.4 Drive and disc states

| Condition | Message | Actions |
|---|---|---|
| No drives | "Connect a disc burner." | None |
| Drive, no disc | "Insert a blank disc." | Open or close the tray, if the drive has one |
| Drive becoming ready | "Reading the disc…" | None |
| Drive in use by another app | "The drive is in use by another app." | None |
| Blank writable disc | "Blank DVD+R, 4.7 GB free" | Burn, Eject |
| Rewritable disc with data | "This DVD-RW has data on it." | Erase, Eject |
| Appendable disc | "This disc already has data on it. Adding to it comes later." | Eject |
| Anything else | "This disc can't be written." | Eject |

### 9.5 Acceptance criteria

1. CI builds everything with zero warnings, and all tests pass.
2. The app runs on macOS 15 and on the current macOS.
3. With no drive, the window shows the no-drive state. Plugging in a USB drive updates it within a few seconds.
4. Inserting a disc updates the state. The window shows the media type and free space, and says whether the disc is blank.
5. Files and folders can be added and removed. Burn is enabled only when there is at least one item and it all fits on the disc.
6. A burn with verification succeeds on CD-R and DVD+R, and on DVD-R and BD-R where available.
7. The burned disc mounts in Finder, and its files match the originals byte for byte.
8. Cancel during writing asks first on write-once media, then stops, and the app stays usable.
9. Removing the disc or drive during a burn gives a clear failure, and the app keeps running.
10. Quick erase works on CD-RW.
11. A verification mismatch, driven by the simulated drive, shows a clear failure.
12. Every control has an accessibility label, and the main flow works with the keyboard alone.
13. Each operation writes a diagnostic log that can be copied from the result screen.

### 9.6 Rough size

About 6 to 10 weeks of focused work, most of it hardware testing. Confidence is low until the first hardware session (task 6).

## 10. Repository, CI and testing

### 10.1 Branches

- `main` holds the new app. It shares no history with `legacy`.
- `legacy` holds Burn. Read it with `git show legacy:burn/Source/KWBurner.m`.
- New work is committed to `main`. If a session starts on a generated branch, merge it into `main` and delete it.

### 10.2 CI

GitHub Actions on macOS runners builds the package and runs its tests on every push. This repository is public, so the runs are free. Runners have no disc drives. The simulated drive stands in for one.

### 10.3 Hardware testing

Hardware tests need the owner's Mac, a drive and blank media. The easiest way is to run Claude Code on that Mac, in the Claude Desktop app or with `claude remote-control` in a terminal in the repository folder. That session can build, run `burnctl` against the drive, and read the logs. The owner inserts and swaps discs. Record every run in `docs/hardware-testing.md`.

## 11. Roadmap after 0.1

- **0.2 Data discs done well.** UDF for large files. Editing the folder structure on the disc. Adding to discs that already have data. A file-by-file check after burning, and an optional checksum file on the disc. Notarised builds and Sparkle 2.
- **0.3 Disc images.** Burn ISO and cue/bin images. Save a disc layout as an ISO image.
- **0.4 Audio CD.** Decoding, gaps and CD-Text, written disc-at-once with a cue sheet. Decoding may need ffmpeg as a helper tool built in CI.
- **0.5 Disc copy.**
- **0.6 DVD-Video.** Conversion, authoring and menus.
- **1.0** Localisation, help, an accessibility review, a wide hardware test matrix, and release.

## 12. Risks and unknowns

| ID | Risk | Response |
|---|---|---|
| R1 | Drive and media quirks. Each drive's firmware behaves a little differently, and write methods vary by media. | Log every command and sense result. Test widely. Turn every hardware failure into a simulator test. |
| R2 | Exclusive access may conflict with macOS's own disc handling, such as the prompt for a blank disc. | Check in the first hardware session. Unmount through Disk Arbitration before taking access. |
| R3 | Apple removes the IOKit authoring interface. | Move the transport to a DriverKit type 05 driver. That needs Apple-approved entitlements and a user-approved system extension. |
| R4 | Writing a disc engine is a large job. | Keep 0.1 to data discs, and grow media support step by step. |
| R5 | Cloud sessions can't use hardware. | CI plus the simulated drive for logic. A local Claude Code session for hardware. |
| R6 | Licence hygiene (D5). | Reference behaviour and standards only. Review pull requests for copied code. |

## 13. Reference map of Burn's source

On the `legacy` branch. Files are in `burn/Source/`.

| Topic | Files |
|---|---|
| Drive list, disc state, burn options, burn status | `KWBurner.m` |
| Erase | `KWEraser.m` |
| Disc and drive information | `KWDiscInfo.m`, `KWRecorderInfo.m` |
| Data disc tree and filesystems | `KWDataController.m`, `KWDRFolder.m`, `FSTreeNode.m` |
| Disc name limits | `KWCommonMethods.m` (`maxLabelLength:`) |
| Audio CD | `KWAudioController.m`, `KWTrackProducer.m` |
| Video conversion and DVD authoring | `KWConverter.m`, `KWDVDAuthorizer.m`, `burn/Themes/` |
| Images and disc copy | `KWCopyController.m`, `KWDiscScanner.m` |

## 14. Format notes from Burn

For later milestones. From Burn's code and commit history.

- Audio CD: 44.1 kHz, 16-bit stereo PCM in 2,352-byte sectors. Pad each track to whole sectors (commit `c8a545b`). Always re-encode (commit `2ae9412`). Track 1 needs a 2-second pregap.
- DVD-Video: take the aspect ratio from the source's display aspect ratio (commits `06bf46c`, `ea8d3fb`). dvdauthor reads PAL or NTSC from `VIDEO_FORMAT`.
- Volume names in Burn: Joliet 16 characters, ISO 9660 30, UDF 126, HFS+ 255.

## 15. Sources

Checked on 29 September 2026.

- macOS 27 release notes: https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
- macOS 26 release notes: https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes
- Xcode 27 release notes: https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes
- MMCDeviceInterface: https://developer.apple.com/documentation/iokit/mmcdeviceinterface
- SCSITaskDeviceInterface: https://developer.apple.com/documentation/iokit/scsitaskdeviceinterface
- SCSIPeripheralsDriverKit: https://developer.apple.com/documentation/scsiperipheralsdriverkit
- schilytools (cdrecord): https://codeberg.org/schilytools/schilytools
- Burn on SourceForge: https://sourceforge.net/p/burn-osx/code-git/ci/master/tree/
