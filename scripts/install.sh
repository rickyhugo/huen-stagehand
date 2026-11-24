#!/bin/sh
set -eu

if [ "$#" -gt 1 ]; then
	echo "Usage: mise run install -- [PREFIX]" >&2
	exit 2
fi

prefix=${1:-"$HOME/.local"}
cd "$(dirname "$0")/.."
test -x zig-out/bin/stagehand
mkdir -p "$prefix/bin"
install -m 755 zig-out/bin/stagehand "$prefix/bin/stagehand"
zig run scripts/package.zig -- notices --dest "$prefix/share/licenses/stagehand"
printf 'Installed %s/bin/stagehand. Add %s/bin to PATH.\n' "$prefix" "$prefix"
