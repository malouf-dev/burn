# Burn (new app)

A disc-burning app for macOS, written in Swift. It has its own burning engine and talks to CD, DVD and Blu-ray drives directly with MMC commands through IOKit. It does not use Apple's DiscRecording framework.

Status: early development, working towards 0.1 alpha. See [docs/proposal.md](docs/proposal.md) for the plan.

The original Objective-C Burn app is on the [`legacy`](../../tree/legacy) branch, kept as a reference.

## What it does now

- Burns files and folders to CD-R, DVD-R and DVD-RW as a UDF 2.01 bridge (UDF with ISO 9660 and Joliet alongside), then reads every block back to check it. Files of any size work; files of 4 GB or more are in UDF only. DVD+R and BD-R are written by the same engine but not yet tested on a real drive. See [docs/hardware-testing.md](docs/hardware-testing.md).
- Puts a hidden `.burn` folder on each disc with a SHA-256 checksum for every file. The app's Verify view checks a disc against it. Without Burn, run this from the disc's root:

```sh
shasum -a 256 -c .burn/SHA256SUMS
```

- Adds PAR2 recovery data to the `.burn` folder, a tenth of the files' size by default. If a check finds damage, Verify's Repair copies the disc's files to a folder you choose and rebuilds the damaged ones. Any PAR2 tool can do the same without Burn: copy the disc to a folder, then run `par2 repair -B<folder> <folder>/.burn/recovery.par2`.
- Makes the disc image as the drive asks for it, so a Blu-ray needs no image-sized temporary file. Recovery data needs one read of the files before the burn, and a temporary file about a tenth of their size.

## Layout

- `App/` holds the SwiftUI app.
- `Packages/BurnKit` holds the engine, the disc image builder, the IOKit transport and the `burnctl` command-line tool.
- `docs/` holds the plan (`proposal.md`), the hardware test log (`hardware-testing.md`), and the development notes (`development-notes.md`): why it's built this way and what we learned.

## Building

Requires macOS 15 or later and Xcode 26 or later.

- The app, without opening Xcode: `scripts/run-app.sh` builds it with `xcodebuild` and opens it. Add `--demo` to use a simulated drive. Xcode must be installed, but needn't be open.
- The app in Xcode: open `Burn.xcodeproj` and run the Burn scheme. To try it without a drive, turn on the `-demo` launch argument in the scheme (Product > Scheme > Edit Scheme > Run > Arguments). It uses a simulated drive with a blank DVD+R.
- The engine and its tests:

```sh
swift build --package-path Packages/BurnKit
swift test --package-path Packages/BurnKit
```

## Trying it with a drive

```sh
swift run --package-path Packages/BurnKit burnctl list
swift run --package-path Packages/BurnKit burnctl status
```

## Licence

MIT. See [LICENSE](LICENSE).
