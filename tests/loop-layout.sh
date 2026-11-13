#!/usr/bin/env bash
# Creates/filesystems ONLY on a newly allocated loop device backed by our temp file.
# Requires Linux root, util-linux, parted, e2fsprogs and dosfstools.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./partition-layout.sh
[[ $EUID -eq 0 ]] || { echo 'Run the loop-image test as root.' >&2; exit 1; }
test_dir=$(mktemp -d)
image=$test_dir/disk.img
loop_device=''
cleanup() {
    if [[ "$test_dir" == /tmp/* ]]; then
        umount -R "$test_dir/os" 2>/dev/null || true
        umount "$test_dir/os.custom-data" 2>/dev/null || true
    fi
    if [[ -n "$loop_device" ]]; then
        # Refuse to detach anything other than this test's verified backing file.
        if [[ $(losetup -n -O BACK-FILE "$loop_device") == "$image" ]]; then
            losetup -d "$loop_device"
        fi
    fi
    [[ "$test_dir" == /tmp/* ]] && rm -rf -- "$test_dir"
}
trap cleanup EXIT
apk() { :; } # CI already has required tools.
is_efi() { [[ $mode == efi ]]; }
xda() {
    case "${1:-}" in
    '') echo "$xda" ;;
    *) echo "${xda}p$1" ;;
    esac
}
update_part() {
    partprobe "$loop_device"
    if command -v udevadm >/dev/null; then udevadm settle; fi
}
fill_zero() { dd if=/dev/zero of="$1" bs=1M count=1 status=none; }
for mode in efi bios; do
    truncate -s 16G "$image"
    loop_device=$(losetup --find --show --partscan "$image")
    [[ "$loop_device" == /dev/loop* ]] || exit 1
    [[ $(losetup -n -O BACK-FILE "$loop_device") == "$image" ]] || exit 1
    xda=${loop_device#/dev/}
    part_root_size=8GiB part_boot_size=512MiB part_data_size=rest
    cp_plan 16384 "$mode" 2048
    cp_create
    mkfs.ext4 -F "$dev_os"
    mkfs.ext4 -F "$dev_boot"
    [[ $(blockdev --getsize64 "$dev_os") -eq $((8 * 1024 * 1024 * 1024)) ]]
    [[ $(blockdev --getsize64 "$dev_boot") -eq $((512 * 1024 * 1024)) ]]
    cp_finish_partitions
    [[ $(blkid -s TYPE -o value "$dev_data") == ext4 ]]
    [[ $(blockdev --getsize64 "$dev_data") -eq $(((p_data_end - p_data_start) * 1048576)) ]]
    mkdir -p "$test_dir/os"
    mount "$dev_os" "$test_dir/os"
    cp_mount_boot "$test_dir/os"
    if [[ "$mode" == efi ]]; then
        mkdir -p "$test_dir/os/boot/efi"
        mount "$dev_efi" "$test_dir/os/boot/efi"
    fi
    mkdir -p "$test_dir/os/etc" "$test_dir/os/data"
    echo preserved-data >"$test_dir/os/data/probe"
    cp_mount_data "$test_dir/os"
    [[ $(cat "$test_dir/os/data/probe") == preserved-data ]]
    echo kernel-probe >"$test_dir/os/boot/kernel-probe"
    echo '# generated in loop test' >"$test_dir/os/etc/fstab"
    cp_write_fstab "$test_dir/os"
    grep -q ' /boot ext4 ' "$test_dir/os/etc/fstab"
    grep -q ' /data ext4 ' "$test_dir/os/etc/fstab"
    if [[ "$mode" == efi ]]; then
        [[ $(blkid -s TYPE -o value "$dev_efi") == vfat ]]
        cp_fix_efi_grub "$test_dir/os"
        grep -q -- "--set=root $(blkid -s UUID -o value "$dev_boot")" "$test_dir/os/boot/efi/EFI/ubuntu/grub.cfg"
    fi
    parted "$loop_device" -s unit MiB print
    umount -R "$test_dir/os"
    # Check actual persistence after unmount/remount, not only the mount table.
    mount "$dev_data" "$test_dir/os"
    [[ $(cat "$test_dir/os/probe") == preserved-data ]]
    umount "$test_dir/os"
    mount "$dev_boot" "$test_dir/os"
    [[ $(cat "$test_dir/os/kernel-probe") == kernel-probe ]]
    umount "$test_dir/os"
    losetup -d "$loop_device"
    loop_device=''
    rm -- "$image"
done
echo 'BIOS and UEFI loop-image tests passed (no OS boot performed).'
