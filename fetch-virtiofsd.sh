#!/usr/bin/env bash
#
# fetch-virtiofsd.sh — download the virtiofsd binary used by the virtiofs patch.
#
# TrueNAS SCALE 25.10 (Debian bookworm base, glibc 2.36) ships no virtiofsd.
# Debian trixie's build needs glibc >= 2.39, so we use Proxmox VE 8's package,
# which is built ON bookworm (needs glibc >= 2.34) and links only against
# libseccomp2 + libcap-ng0 + libgcc-s1 — all present on TrueNAS.
#
# Run as the regular user on the NAS (no sudo needed); installs next to this
# script. The binary lives on /mnt/apps so it SURVIVES TrueNAS upgrades —
# normally this only ever needs to run once.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB_URL="http://download.proxmox.com/debian/pve/dists/bookworm/pve-no-subscription/binary-amd64/virtiofsd_1.10.1-1~bpo12+pve1_amd64.deb"
DEB_SHA256="53eb40f61d58bd0fdb195fcc5075a2aea074a02bfb48f623ea9843249d892706"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $DEB_URL ..."
curl -sL -o "$tmp/virtiofsd.deb" "$DEB_URL"
echo "$DEB_SHA256  $tmp/virtiofsd.deb" | sha256sum -c - || {
    echo "ERROR: checksum mismatch — refusing to install." >&2; exit 1;
}

(cd "$tmp" && ar x virtiofsd.deb && tar -xf data.tar.xz)
install -m 0755 "$tmp/usr/libexec/virtiofsd" "$SCRIPT_DIR/virtiofsd"

echo "Installed: $SCRIPT_DIR/virtiofsd"
"$SCRIPT_DIR/virtiofsd" --version
