#!/usr/bin/env bash
# Everything a commit must pass: format, tests and the architecture rules.
set -euo pipefail

cd "$(dirname "$0")/.."

zig fmt --check build.zig src

zig build test

# Only remote/ and image/ start processes.
if grep -rnE 'process\.(spawn|run|Child)' src --include='*.zig' | grep -vE '^src/(remote|image)/'; then
	echo "only src/remote/ and src/image/ may start processes"
	exit 1
fi

# The core reaches the outside only through the remote port.
if [ -d src/deploy ] && grep -rnE 'std\.(net|Io\.net)|Io\.Dir|Io\.File' src/deploy --include='*.zig'; then
	echo "src/deploy/ must not reach the outside: use the remote port"
	exit 1
fi

echo "check passed"
