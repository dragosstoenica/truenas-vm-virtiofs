# truenas-vm-virtiofs

**virtiofs host-path shares for TrueNAS SCALE VMs** — mount a NAS dataset
inside a libvirt VM at near-local speed, with your data staying on ZFS
(snapshots, replication, the works).

TrueNAS SCALE **25.10** (Goldeye) runs VMs on libvirt + QEMU, both fully
virtiofs-capable — but ships no `virtiofsd` and no way to configure a share.
This project fills the gap with a small, fail-safe middleware patch:

- Declare shares per-VM in a simple `shares.json`
- **libvirt spawns and supervises `virtiofsd` itself** — no systemd units, no
  daemon babysitting, one virtiofsd per share per running VM
- **Fail-safe by design**: if anything is missing (config, binary, source dir,
  or the patch itself after a TrueNAS upgrade), VMs boot normally — just
  without the share

## Why bother? Benchmarks

Small-file workloads (git, npm, build tools) are where NFS hurts. Measured on
the same dataset, same VM (1000 × small files):

| operation | virtiofs | NFS 4.2 (nconnect=8) |
|---|---|---|
| create 1000 files | **0.41s** | 8.87s |
| delete 1000 files | **0.12s** | 3.92s |
| read sweep | **0.10s** | 0.36s |
| stat sweep | 0.08s | 0.07s |

> ⚠️ **Disclaimer**: this patches a TrueNAS system file (in the current boot
> environment only, with backups and a drift guard). It works for me; review
> the code and use at your own risk. Re-apply after every TrueNAS upgrade.

---

## How it works

`middleware-virtiofs.patch.in` patches `domain_children()` in
`/usr/lib/python3/dist-packages/middlewared/plugins/vm/supervisor/domain_xml.py`
so that when a VM listed in `shares.json` starts, its libvirt domain XML gains:

```xml
<memoryBacking>            <!-- vhost-user-fs requires shared guest memory -->
  <source type='memfd'/>
  <access mode='shared'/>
</memoryBacking>
<devices>
  <filesystem type='mount' accessmode='passthrough'>
    <driver type='virtiofs' queue='1024'/>
    <binary path='/usr/libexec/virtiofsd' xattr='on'/>
    <source dir='/mnt/tank/dev'/>
    <target dir='dev'/>
  </filesystem>
</devices>
```

The patch is wrapped in try/except and skips silently on any problem, so it
can never prevent a VM from starting.

The `virtiofsd` binary is **Proxmox VE 8's bookworm build** (1.10.1) — TrueNAS
25.10 is Debian bookworm-based (glibc 2.36) and Debian trixie's own virtiofsd
needs glibc ≥ 2.39. `fetch-virtiofsd.sh` downloads it with checksum
verification; `apply-patch.sh` installs it to `/usr/libexec/virtiofsd`.

## Install

Clone onto a dataset on a data pool (NOT the boot pool), e.g.
`/mnt/tank/truenas-vm-virtiofs` — it survives upgrades there:

```bash
git clone https://github.com/dragosstoenica/truenas-vm-virtiofs.git /mnt/tank/truenas-vm-virtiofs
cd /mnt/tank/truenas-vm-virtiofs
./fetch-virtiofsd.sh                  # download virtiofsd (no sudo needed)
cp shares.json.example shares.json    # then edit: VM name -> shares
sudo ./apply-patch.sh                 # patch middleware + install binary + restart middlewared
```

Then **stop and start** the VM (not an in-guest reboot — the domain XML is
rebuilt on VM start).

In the guest, mount by tag (fstab):

```
dev  /mnt/dev  virtiofs  defaults,nofail  0  0
```

Editing `shares.json` later needs no patch re-apply and no middleware restart
— just stop/start the affected VM.

## Migrating from an existing NFS mount

If the guest already mounts the same dataset over NFS, let virtiofs take over
the path and keep NFS as a lazy fallback (handy after TrueNAS upgrades, when
the share is absent until you re-apply the patch). In the guest's
`/etc/fstab`, move the NFS entry to a fallback mountpoint and add the
virtiofs line at the original one:

```
dev  /mnt/dev  virtiofs  defaults,nofail  0  0
192.168.1.10:/mnt/tank/dev  /mnt/dev-nfs  nfs4  vers=4.2,noatime,_netdev,x-systemd.automount,nofail  0  0
```

`nofail` on both means boot can never hang; `x-systemd.automount` mounts the
fallback only when something actually touches it. Create both mountpoints,
`systemctl daemon-reload`, then stop/start the VM. Check the **Gotchas**
below before you do — the NFS→virtiofs switch is exactly where the NIC-rename
and uid traps bite.

## Gotchas (learned the hard way)

- **AppArmor**: libvirt may only exec virtiofsd from `/usr/libexec/virtiofsd`
  (and a few other blessed paths). Running it from `/mnt/...` fails with
  exit 126 "Permission denied" — that's why `apply-patch.sh` copies it to the
  boot pool.
- **NIC rename / lost networking**: adding the `<filesystem>` device shifts
  the NIC's PCI slot (libvirt orders filesystems before interfaces in the
  domain XML), which renames the guest interface — netplan stops matching it
  and the VM boots with **no network**. Fix at the VM console, then prevent it
  permanently by pinning the name to the MAC (from the TrueNAS VM device list)
  with `/etc/systemd/network/10-persistent-net.link` in the guest:

  ```ini
  [Match]
  MACAddress=xx:xx:xx:xx:xx:xx

  [Link]
  Name=ens4        # whatever your netplan config references
  ```

  then `sudo update-initramfs -u`.
- **UIDs pass through 1:1**: unlike an NFS export with `mapall`, virtiofs
  presents host file ownership as-is. Make the guest user's uid/gid match the
  dataset owner on the host, e.g. in the guest (from a root session while the
  user is logged out):

  ```bash
  groupmod -g 3000 youruser
  usermod -u 3000 -g 3000 youruser
  chown -R 3000:3000 /home/youruser
  ```

  …or fix ownership on the dataset instead, if nothing else (SMB, other
  clients) depends on it.
- **Guest support**: the guest kernel needs `CONFIG_VIRTIO_FS` (any modern
  distro has it — Ubuntu, Debian, Fedora all fine).

## After a TrueNAS upgrade

Upgrades create a fresh boot environment: the middleware patch AND
`/usr/libexec/virtiofsd` are gone (your `shares.json` + this directory
survive on the data pool). VMs boot fine without shares; to restore:

```bash
cd /mnt/tank/truenas-vm-virtiofs
sudo ./apply-patch.sh --dry-run   # verify the patch still fits the new middleware
sudo ./apply-patch.sh             # re-apply patch + binary, restart middlewared
# then stop & start the VMs that use shares
```

If `--dry-run` reports a mismatch, the middleware source changed — regenerate
the diff against the new `domain_xml.py` and retry.

## Commands

```bash
sudo ./apply-patch.sh             # apply (idempotent, backs up, syntax-checks)
sudo ./apply-patch.sh --status    # patch applied? binary installed?
sudo ./apply-patch.sh --dry-run   # would it apply cleanly?
sudo ./apply-patch.sh --revert    # undo everything (reverse-patch or backup restore)
```

Verify a running setup:

```bash
ps aux | grep [v]irtiofsd                        # a process pair per share while its VM runs
# in the guest:
mount | grep virtiofs
```

## License

MIT — see [LICENSE](LICENSE).
