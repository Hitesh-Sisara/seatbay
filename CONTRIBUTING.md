# Contributing to Seatbay

Thanks for helping! Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an [issue](https://github.com/Hitesh-Sisara/seatbay/issues/new/choose) with your macOS version,
Claude version, Seatbay version, what you did and what happened. These usually help:

```bash
S="/Applications/Seatbay.app/Contents/MacOS/Seatbay"
"$S" --health
"$S" --backup-schedule status
tail -50 ~/Library/Application\ Support/Seatbay/Logs/launcher.log
tail -50 ~/Library/Application\ Support/Seatbay/Logs/backup.log
```

Please remove anything private (account emails, hostnames, bucket names) before posting. Never post
the contents of `secrets.json` or a Claude data folder.

## Development

- macOS 14+, Xcode 16+ (Swift 5.10+) and Claude Desktop in `/Applications`.
- `swift build` builds everything, `swift test` runs the unit tests, and
  `./scripts/build.sh --install` builds `Seatbay.app` and copies it to `~/Applications`.
- The website lives in `website/` (vinext on Cloudflare Workers); see `website/README.md`.

### Trying changes without touching your own setup

Seatbay keeps everything under your home folder, so you can point it at a throwaway one:

```bash
B="$(swift build -c release --show-bin-path)/Seatbay"
mkdir -p /tmp/sb-home
CFFIXED_USER_HOME=/tmp/sb-home "$B" --list
open -n -g build/Seatbay.app --env CFFIXED_USER_HOME=/tmp/sb-home   # the app, in the test home
```

Instance apps made there pass `CFFIXED_USER_HOME` on to Claude, so the whole test stays in
`/tmp/sb-home`. Don't turn on nightly backups in a test home: the launchd agent is per user, not per
home folder.

Two helpers draw the UI without a screen, handy for checking layouts and in reviews:

```bash
CFFIXED_USER_HOME=/tmp/sb-home "$B" --render-view main /tmp/main.png      # also editor, editor-api, nightly, backups
"$B" --render-preview /tmp/icon.png Green 3 colorAndNumber WORK --api      # an instance icon (needs Claude installed)
open -a Seatbay --args -SBInitialTab backups                               # open on a given tab
```

## Pull requests

- Keep each pull request to one change, and describe what it does and how you tested it.
- Add or update tests for logic you change (`Tests/SeatbayTests`); CI runs `swift test` and a full
  app build on macOS.
- Anything that moves, deletes or overwrites a user's Claude data, backups or apps needs extra care:
  explain the failure cases in the pull request.
- Write user-facing text in plain English, as you'd explain it to a colleague.

## Releases

Maintainers run `scripts/release.sh <version>`: it moves the "Unreleased" changelog entries under the
new version, updates `VERSION`, commits, tags `v<version>` and pushes. The tag triggers the Release
workflow, which builds a universal `Seatbay.zip`, runs the tests and publishes the GitHub release.

## Code of conduct

This project follows the [Contributor Covenant 2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).
Be kind and constructive. Report unacceptable behaviour to the maintainer through
[GitHub](https://github.com/Hitesh-Sisara).
