#!/usr/bin/env bash
# Installs the latest DDEV release from GitHub into DDEV_INSTALL_DIR (default /usr/local/bin).
# Used inside sbx, where pkg.ddev.com (apt repo) is not reachable through the proxy but GitHub is.
# Run by the launcher through `sbx exec -i <sandbox> bash -s` and by the hook as a fallback.
# Prints one indented line per step; the last one is "installed DDEV <version> into <dir>".

install_dir="${DDEV_INSTALL_DIR:-/usr/local/bin}"

# Every step checks its own status: set -e is ignored when the function runs inside an if condition.
install_ddev() {
    local arch ver tarball tmp sudo_cmd bin
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64 | arm64) arch=arm64 ;;
        *) echo "    unsupported architecture $(uname -m)"; return 1 ;;
    esac
    echo "    resolving the latest DDEV release"
    ver="$(curl -fsSI https://github.com/ddev/ddev/releases/latest | grep -i '^location' | sed 's#.*/tag/##' | tr -d '\r')"
    [ -n "$ver" ] || { echo "    could not resolve latest DDEV version"; return 1; }
    tarball="ddev_linux-$arch.$ver.tar.gz"
    tmp="$(mktemp -d)" || return 1
    trap 'rm -rf "$tmp"' RETURN
    echo "    downloading $tarball"
    curl -fsSL -o "$tmp/$tarball" "https://github.com/ddev/ddev/releases/download/$ver/$tarball" || return 1
    curl -fsSL -o "$tmp/checksums.txt" "https://github.com/ddev/ddev/releases/download/$ver/checksums.txt" || return 1
    echo "    verifying the checksum"
    (cd "$tmp" && grep " $tarball\$" checksums.txt | sha256sum -c - >/dev/null) || return 1
    tar -xzf "$tmp/$tarball" -C "$tmp" </dev/null || return 1
    sudo_cmd=""
    [ -w "$install_dir" ] || sudo_cmd="sudo -n"
    for bin in ddev ddev-hostname mkcert; do
        $sudo_cmd install -m 0755 "$tmp/$bin" "$install_dir/$bin" </dev/null || return 1
    done
    echo "installed DDEV $ver into $install_dir"
}

install_ddev
