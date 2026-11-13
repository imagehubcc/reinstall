# reinstall: configurable partitions

Fork of [bin456789/reinstall](https://github.com/bin456789/reinstall) with configurable GPT partitions for Linux-to-Ubuntu 24.04 x86_64 cloud-image installation.

**Reinstallation erases the entire target disk, including any existing `/data` partition. Back up data first.**

## Usage

Clone the complete repository:

```sh
git clone --branch main https://github.com/imagehubcc/reinstall.git
cd reinstall
sudo bash reinstall.sh ubuntu 24.04 \
  --root-size 64GiB --boot-size 2GiB --data-size rest --hold 2
```

Follow the login setup prompts, then reboot to start installation. With `--hold 2`, the installer pauses after completion with the new system mounted at `/os`; inspect it and reboot into Ubuntu. Omit this option for an automatic final reboot.

BIOS/UEFI is detected automatically. UEFI defaults to a 512MiB EFI partition; BIOS uses a 1MiB BIOS-GRUB partition. `--efi-size` is an optional UEFI-only override and is rejected on BIOS before disk partitioning.

| Option | Purpose |
| --- | --- |
| `--root-size SIZE` | Required for custom layouts; minimum 8GiB |
| `--boot-size SIZE` | Optional separate `/boot`; minimum 512MiB; omit or use `0` to keep it in root |
| `--data-size SIZE` or `--data-size rest` | Optional data partition; minimum 1GiB |
| `--data-mount /PATH` | Data mount point; default `/data` |
| `--efi-size SIZE` | Optional UEFI size override; default 512MiB, minimum 100MiB |

Sizes accept positive integers in MiB/GiB/TiB, MB/GB/TB, or binary aliases M/G/T. Fixed allocations leave extra space unallocated. Use `--ssh-port PORT` if a non-default SSH port is required.

Custom layouts do not support other OS versions, ARM, Windows entry points, ISO installation, LVM, software RAID, array creation or reconfiguration, encryption, or preserving existing partitions. Without custom options, the original upstream flow remains available.

See the [Chinese README](README.md), [partition and maintenance guide](CUSTOM-PARTITIONS.md), [validation scope](VPS-VALIDATION.md), and [upstream documentation](https://github.com/bin456789/reinstall#readme).
