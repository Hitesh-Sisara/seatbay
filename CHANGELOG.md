# Changelog

All notable changes to Seatbay are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-11-19

First public release. Seatbay was called "Multi Claude" before this release; existing installs keep
their data (see "Upgrading from Multi Claude" in the README).

### Added
- Instances: several Claude Desktop apps side by side, each with its own account, data folder and
  private APFS copy of Claude, so the regular Claude icon keeps opening your main Claude.
- Coloured, numbered Dock icons with an optional label strip and an `API` tag for API instances.
- Sign-in relay: sign an instance in without quitting the others.
- API instances: Anthropic API key or any Anthropic-compatible gateway, with a free connection test.
- Backups on quit and a nightly round (02:00–03:00 by default) that also backs up open Claudes,
  catches up after sleep, and retries failed uploads; encrypted upload to S3-compatible storage;
  restore and restore as a new instance.
- Safe updates with signature check and roll back, Health, Sleep idle instances, copy to another Mac,
  bypass-permissions default, and a full command line.
- Unit tests, CI, release automation and the website at https://seatbay.sisara.in.

[Unreleased]: https://github.com/Hitesh-Sisara/seatbay/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Hitesh-Sisara/seatbay/releases/tag/v1.0.0
