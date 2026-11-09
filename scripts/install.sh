#!/usr/bin/env bash
# Installs the latest Cowshed release, checked against its SHA256SUMS.
#
#   curl -fsSL https://raw.githubusercontent.com/llllOllOOll/cowshed/main/scripts/install.sh | bash
#
# COWSHED_INSTALL_DIR  where it goes (default /usr/local/bin, with sudo when needed)
# COWSHED_VERSION      a release such as 0.1.0 instead of the latest
#
# The whole script is a function, called on its last line: a download cut
# halfway runs nothing.
set -euo pipefail

# Global: the cleanup on exit runs after main has returned.
temporary=""

main() {
	local repository="llllOllOOll/cowshed"
	local install_dir="${COWSHED_INSTALL_DIR:-/usr/local/bin}"
	local version="${COWSHED_VERSION:-}"

	local os arch
	case "$(uname -s)" in
		Linux) os=linux ;;
		Darwin) os=macos ;;
		*) fail "no release for $(uname -s); build it from the source" ;;
	esac
	case "$(uname -m)" in
		x86_64 | amd64) arch=x86_64 ;;
		aarch64 | arm64) arch=aarch64 ;;
		*) fail "no release for $(uname -m); build it from the source" ;;
	esac
	local asset="cowshed-${os}-${arch}"

	local tag
	if [ -n "$version" ]; then
		tag="v${version#v}"
	else
		tag=$(curl -fsSL "https://api.github.com/repos/${repository}/releases/latest" |
			sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1) ||
			fail "could not ask GitHub for the latest release"
		[ -n "$tag" ] || fail "GitHub has no release of ${repository}"
	fi

	temporary=$(mktemp -d)
	trap 'rm -rf "$temporary"' EXIT

	say "downloading ${asset} ${tag}"
	local base="https://github.com/${repository}/releases/download/${tag}"
	curl -fsSL -o "${temporary}/${asset}" "${base}/${asset}" || fail "could not download ${base}/${asset}"
	curl -fsSL -o "${temporary}/SHA256SUMS" "${base}/SHA256SUMS" || fail "could not download ${base}/SHA256SUMS"

	local expected actual
	expected=$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1 }' "${temporary}/SHA256SUMS")
	[ -n "$expected" ] || fail "SHA256SUMS of ${tag} has no line for ${asset}"
	if command -v sha256sum >/dev/null; then
		actual=$(sha256sum "${temporary}/${asset}" | awk '{ print $1 }')
	else
		actual=$(shasum -a 256 "${temporary}/${asset}" | awk '{ print $1 }')
	fi
	[ "$expected" = "$actual" ] || fail "${asset} does not match its SHA-256 in SHA256SUMS; nothing was installed"
	chmod 755 "${temporary}/${asset}"

	# Into the folder under a temporary name, then renamed over: a cowshed
	# running meanwhile keeps its file.
	local sudo=""
	if ! { mkdir -p "$install_dir" 2>/dev/null && [ -w "$install_dir" ]; }; then
		sudo=sudo
		command -v sudo >/dev/null || fail "no permission to write in ${install_dir}, and no sudo; set COWSHED_INSTALL_DIR"
		say "${install_dir} needs sudo"
		sudo mkdir -p "$install_dir"
	fi
	$sudo cp "${temporary}/${asset}" "${install_dir}/.cowshed-install"
	$sudo mv -f "${install_dir}/.cowshed-install" "${install_dir}/cowshed"

	say "installed ${install_dir}/cowshed $("${install_dir}/cowshed" version)"
	case ":${PATH}:" in
		*":${install_dir}:"*) ;;
		*) say "${install_dir} is not in PATH: add it to run \`cowshed\`" ;;
	esac
}

say() {
	printf 'cowshed: %s\n' "$1"
}

fail() {
	printf 'cowshed: stopped: %s\n' "$1" >&2
	exit 1
}

main "$@"
