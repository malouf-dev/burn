# Burn (new app)

A disc-burning app for macOS, written in Swift. It has its own burning engine and talks to CD, DVD and Blu-ray drives directly with MMC commands through IOKit. It does not use Apple's DiscRecording framework.

Status: early development, working towards 0.1 alpha. See [docs/proposal.md](docs/proposal.md) for the plan.

The original Objective-C Burn app is on the [`master`](../../tree/master) branch, kept as a reference.

## Layout

- `Packages/BurnKit` holds the engine, the disc image builder, the IOKit transport and the `burnctl` command-line tool.
- `docs/` holds the plan and the hardware test log.

## Building

Requires macOS 15 or later and Xcode 26 or later.

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
