#!/usr/bin/env bash
#
# apply-patch.sh — apply / revert the TrueNAS middleware virtiofs patch.
#
# Adds virtiofs host-path shares to libvirt VMs listed in shares.json (same
# directory). libvirt spawns and supervises virtiofsd itself; if this patch is
# missing (e.g. after a TrueNAS upgrade) VMs still boot — just without shares.
#
# Run MANUALLY as root — once now, and again after every TrueNAS OS upgrade
# (an upgrade creates a fresh boot environment with pristine middleware files):
#
#     sudo ./apply-patch.sh            # apply (idempotent, safe, backs up first)
#     sudo ./apply-patch.sh --status   # is it applied?
#     sudo ./apply-patch.sh --dry-run  # test whether the patch still fits
#     sudo ./apply-patch.sh --revert   # undo (reverse patch, else restore backup)
#
# Safety: before applying, it runs `patch --dry-run`. If the middleware source
# has drifted (e.g. after an upgrade) the patch will NOT apply cleanly and this
# script REFUSES rather than risk corrupting middleware — refresh the .patch and
# retry. Every target file is backed up under backups/<UTC-timestamp>/ first.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_TEMPLATE="${SCRIPT_DIR}/middleware-virtiofs.patch.in"
ROOT="/usr/lib/python3/dist-packages/middlewared"
MARKER="virtiofs patch"
# canonical path — the only virtiofsd location libvirt's AppArmor profile
# permits; wiped by TrueNAS upgrades, reinstalled from SCRIPT_DIR on apply
BINARY_DST="/usr/libexec/virtiofsd"

# Render the patch template: the patched middleware reads shares.json from
# wherever this directory lives (@VIRTIOFS_BASE@ -> SCRIPT_DIR).
[ -r "$PATCH_TEMPLATE" ] || { echo "ERROR: template not found: $PATCH_TEMPLATE" >&2; exit 1; }
PATCH="$(mktemp)"
trap 'rm -f "$PATCH"' EXIT
sed "s|@VIRTIOFS_BASE@|${SCRIPT_DIR}|g" "$PATCH_TEMPLATE" > "$PATCH"
FILES=(
    "plugins/vm/supervisor/domain_xml.py"
)

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root — use: sudo $0 ${1:-}"
[ -r "$PATCH" ]      || die "patch file not found: $PATCH"

is_applied() {
    local f
    for f in "${FILES[@]}"; do
        grep -q "$MARKER" "$ROOT/$f" 2>/dev/null || return 1
    done
    return 0
}

restart_mw() {
    echo "Restarting middlewared so the patched code is loaded ..."
    if systemctl restart middlewared; then
        echo "middlewared restarted."
    else
        echo "WARNING: 'systemctl restart middlewared' failed — restart it manually."
    fi
    echo "NOTE: running VMs keep their old domain XML — stop & start a VM to attach its shares."
}

case "${1:-apply}" in
    --status|status)
        if is_applied; then echo "Patch is APPLIED."; else echo "Patch is NOT applied."; fi
        if [ -x "$BINARY_DST" ]; then echo "virtiofsd is installed at $BINARY_DST."
        else echo "virtiofsd is NOT installed at $BINARY_DST."; fi
        ;;

    --dry-run|dry-run)
        echo "Dry-run against $ROOT:"
        patch -p1 -d "$ROOT" --dry-run < "$PATCH"
        ;;

    --revert|revert)
        if ! is_applied; then echo "Patch not applied; nothing to revert."; exit 0; fi
        echo "Reverting patch ..."
        if patch -p1 -R -d "$ROOT" --dry-run < "$PATCH" >/dev/null 2>&1; then
            patch -p1 -R -d "$ROOT" < "$PATCH"
            echo "Reverted via reverse-patch."
        else
            newest="$(ls -1d "$SCRIPT_DIR"/backups/*/ 2>/dev/null | tail -1)"
            [ -n "$newest" ] || die "cannot reverse-apply and no backup found under backups/"
            echo "Reverse-apply failed; restoring originals from: $newest"
            for f in "${FILES[@]}"; do
                if [ -f "$newest/$f" ]; then
                    cp -a "$newest/$f" "$ROOT/$f" && echo "  restored $f"
                else
                    echo "  WARNING: no backup for $f in $newest"
                fi
            done
        fi
        rm -f "$BINARY_DST" && echo "Removed $BINARY_DST."
        restart_mw
        ;;

    apply|--apply|"")
        if is_applied; then
            echo "Patch already applied (marker present) — nothing to do."
            exit 0
        fi
        echo "Verifying the patch still matches this middleware build ..."
        dr="$(mktemp)"
        if ! patch -p1 -d "$ROOT" --dry-run < "$PATCH" >"$dr" 2>&1; then
            echo "------------------------------------------------------------------"
            cat "$dr"; rm -f "$dr"
            echo "------------------------------------------------------------------"
            die "patch does NOT apply cleanly (middleware source changed?). Refusing.
      Refresh middleware-virtiofs.patch against the new source, then retry."
        fi
        rm -f "$dr"

        ts="$(date -u +%Y%m%dT%H%M%SZ)"
        bdir="${SCRIPT_DIR}/backups/${ts}"
        echo "Backing up originals to ${bdir}"
        for f in "${FILES[@]}"; do
            mkdir -p "${bdir}/$(dirname "$f")"
            cp -a "${ROOT}/${f}" "${bdir}/${f}"
        done

        echo "Applying patch ..."
        patch -p1 -d "$ROOT" < "$PATCH" || die "apply failed — originals are safe in ${bdir}"

        echo "Syntax-checking patched files ..."
        for f in "${FILES[@]}"; do
            python3 -c "import ast; ast.parse(open('${ROOT}/${f}').read())" \
                || die "post-patch syntax error in ${f} — restore with: sudo $0 --revert (backup: ${bdir})"
        done

        echo "Installing virtiofsd to ${BINARY_DST} (AppArmor-approved path) ..."
        [ -x "${SCRIPT_DIR}/virtiofsd" ] || die "virtiofsd not found in ${SCRIPT_DIR} — run ./fetch-virtiofsd.sh first"
        install -m 0755 "${SCRIPT_DIR}/virtiofsd" "$BINARY_DST"

        echo "Patch applied and syntax-checked (backup: ${bdir})."
        restart_mw
        ;;

    -h|--help|help)
        echo "Usage: sudo $0 [apply|--status|--dry-run|--revert]"
        ;;
    *)
        die "unknown option '$1' (try --help)"
        ;;
esac
