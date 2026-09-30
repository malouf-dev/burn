# Burn (new app)

A disc-burning app for macOS, written in Swift. It has its own burning engine and talks to CD, DVD and Blu-ray drives directly with MMC commands through IOKit. It does not use Apple's DiscRecording framework.

Status: early development, working towards 0.1 alpha. See [docs/proposal.md](docs/proposal.md) for the plan.

The original Objective-C Burn app is on the [`legacy`](../../tree/legacy) branch, kept as a reference.

## What it does now

- Burns files and folders to CD-R, DVD-R and DVD-RW as ISO 9660 with Joliet, then reads every block back to check it. DVD+R and BD-R are written by the same engine but not yet tested on a real drive. See [docs/hardware-testing.md](docs/hardware-testing.md).
- Puts a hidden `.burn` folder on each disc with a SHA-256 checksum for every file. The app's Verify view checks a disc against it. Without Burn, run this from the disc's root:

```sh
shasum -a 256 -c .burn/SHA256SUMS
```

## Layout

- `App/` holds the SwiftUI app.
- `Packages/BurnKit` holds the engine, the disc image builder, the IOKit transport and the `burnctl` command-line tool.
- `docs/` holds the plan and the hardware test log.

## Building

Requires macOS 15 or later and Xcode 26 or later.

- The app: open `Burn.xcodeproj` and run the Burn scheme. To try it without a drive, turn on the `-demo` launch argument in the scheme (Product > Scheme > Edit Scheme > Run > Arguments). It uses a simulated drive with a blank DVD+R.
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
