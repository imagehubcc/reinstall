# reinstall: configurable partitions

Fork of [bin456789/reinstall](https://github.com/bin456789/reinstall) with configurable GPT partitions for Linux-to-Ubuntu 24.04 x86_64 cloud-image installation.

**Reinstallation erases the entire target disk, including any existing `/data` partition. Back up data first.**

## Usage

Clone the complete repository:

```sh
git clone --branch main https://github.com/imagehubcc/reinstall.git
cd reinstall
sudo bash reinstall.sh ubuntu 24.04 \
  --username root --password 'YOUR_ROOT_PASSWORD' \
  --ssh-port 2222 \
  --root-size 64GiB --boot-size 2GiB --data-size rest --hold 2
```

`--username root` selects the root account; `--password` sets the selected account's password. Replace `YOUR_ROOT_PASSWORD` with your own password. Omit these options to configure login interactively.

- Use single quotes around passwords to protect characters such as `$`, `!`, and spaces from shell interpretation; the quotes are not part of the password. If the password contains a single quote, omit `--password` and enter it at the prompt instead. Interactive entry also avoids storing the password in shell history.
- On Ubuntu, `--username alice` creates a regular account with home directory `/home/alice` and uses the supplied password for that account. It grants passwordless sudo, including `sudo -i` for a root shell; it does not also set root's password or explicitly enable root SSH password login.

`--ssh-port 2222` sets the new system’s SSH port to 2222. Replace it with your preferred port and allow access in your firewall or security group. Omit this option to use port 22. After installation, connect with `ssh -p 2222 root@SERVER_IP`.

Reboot after preparation to start installation. With `--hold 2`, the installer pauses after completion with the new system mounted at `/os`; inspect it and reboot into Ubuntu. Omit this option for an automatic final reboot.

BIOS/UEFI is detected automatically. UEFI defaults to a 512MiB EFI partition; BIOS uses a 1MiB BIOS-GRUB partition. `--efi-size` is an optional UEFI-only override and is rejected on BIOS before disk partitioning.

| Option | Purpose |
| --- | --- |
| `--root-size SIZE` or `--root-size rest` | Optional; fixed size minimum 8GiB; omission rules below |
| `--boot-size SIZE` | Optional separate `/boot`; minimum 512MiB; omit or use `0` to keep it in root |
| `--data-size SIZE` or `--data-size rest` | Optional data partition; minimum 1GiB; `0` disables it |
| `--data-mount /PATH` | Data mount point; default `/data` |
| `--efi-size SIZE` | Optional UEFI size override; default 512MiB, minimum 100MiB |

For a separate 2GiB boot partition with all remaining space assigned to root:

```sh
sudo bash reinstall.sh ubuntu 24.04 --target-disk /dev/nvme0n1 --boot-size 2GiB
```

An explicit `--root-size rest` is also supported. Login options can be added as needed.

Omitted options use these defaults:

- Boot/EFI-only or explicit root `rest`: remaining space goes to root, with no data partition.
- Fixed data size without a root size: root receives the remaining space after data.
- Data `rest` requires an explicit fixed `--root-size SIZE`; omission produces a message asking you to supply it, rather than choosing a size for you.
- A data mount point without a data size implies data `rest` and likewise requires an explicit fixed root size.
- Explicit root `rest` plus data `rest`, or data `0` plus a mount point, is rejected as conflicting. Invalid values and insufficient capacity are also rejected.

Sizes accept positive integers in MiB/GiB/TiB, MB/GB/TB, or binary aliases M/G/T. When both root and data have fixed sizes, extra space stays unallocated.

**Custom partitions currently support only Linux-to-Ubuntu 24.04 x86_64 cloud-image installation.** Without custom partition options, the original upstream script’s default installation behavior and features apply.

Custom layouts do not support other OS versions, ARM, Windows entry points, ISO installation, LVM, software RAID, array creation or reconfiguration, encryption, or preserving existing partitions.

See the [Chinese README](README.md), [partition and maintenance guide](CUSTOM-PARTITIONS.md), [validation scope](VPS-VALIDATION.md), and [upstream documentation](https://github.com/bin456789/reinstall#readme).

## Upstream synchronization

The daily workflow checks upstream at 01:23 UTC. A merged candidate must pass offline checks,
loop-image tests and complete BIOS/UEFI QEMU reinstall/boot tests before main is advanced.
Conflicts, failures or concurrent main changes stop publication and create/update an assigned GitHub Issue.
Tests use GitHub-hosted runners, with no server credentials. Manual verification is available in Actions.
