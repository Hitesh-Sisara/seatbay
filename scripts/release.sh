#!/bin/bash
# Cuts a release: scripts/release.sh 1.1.0
#   - moves the "Unreleased" changelog entries under the new version (with today's date)
#   - writes VERSION, commits, tags v<version> and pushes; the tag starts the Release workflow,
#     which builds the universal Seatbay.zip and publishes the GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version, e.g. 1.1.0>}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "commit or stash your changes first" >&2; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION already exists" >&2; exit 1; }

TODAY="$(date +%Y-%m-%d)"
python3 - "$VERSION" "$TODAY" <<'PY'
import re, sys
version, today = sys.argv[1], sys.argv[2]
path = "CHANGELOG.md"
text = open(path).read()
if "## [Unreleased]" not in text:
    sys.exit("CHANGELOG.md has no [Unreleased] section")
text = text.replace("## [Unreleased]", f"## [Unreleased]\n\n## [{version}] - {today}", 1)
repo = "https://github.com/Hitesh-Sisara/seatbay"
text = re.sub(r"^\[Unreleased\]: .*$", f"[Unreleased]: {repo}/compare/v{version}...HEAD\n[{version}]: {repo}/releases/tag/v{version}",
              text, count=1, flags=re.M)
open(path, "w").write(text)
PY
echo "$VERSION" > VERSION
swift test
git add CHANGELOG.md VERSION
git commit -m "Release $VERSION"
git tag -a "v$VERSION" -m "Seatbay $VERSION"
git push origin HEAD "v$VERSION"
echo "Pushed v$VERSION; the Release workflow builds and publishes it."
