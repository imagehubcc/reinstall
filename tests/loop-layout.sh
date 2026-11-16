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
for layout in fixed-root boot-only root-rest auto-root-data mount-only multi-rest multi-root-rest multi-fixed; do
    truncate -s 32G "$image"
    loop_device=$(losetup --find --show --partscan "$image")
    [[ "$loop_device" == /dev/loop* ]] || exit 1
    [[ $(losetup -n -O BACK-FILE "$loop_device") == "$image" ]] || exit 1
    xda=${loop_device#/dev/}
    unset part_root_size part_data_size part_data_mount part_data_specs
    part_boot_size=512MiB
    case "$layout" in
        fixed-root) part_root_size=8GiB part_data_size=rest ;;
        boot-only) : ;;
        root-rest) part_root_size=rest ;;
        auto-root-data) part_data_size=1GiB ;;
        mount-only) part_root_size=8GiB part_data_mount=/data part_boot_size=0 ;;
        multi-rest) part_root_size=8GiB part_data_specs=rest:/data,2GiB:/home,3GiB:/opt ;;
        multi-root-rest) part_root_size=rest part_data_specs=1GiB:/home,1GiB:/opt ;;
        multi-fixed) part_root_size=8GiB part_data_specs=2GiB:/home,3GiB:/opt ;;
    esac
    echo "Testing $mode / $layout"
    cp_plan 32768 "$mode" 2048
    cp_create
    mkfs.ext4 -F "$dev_os"
    if [[ -n "$dev_boot" ]]; then
        mkfs.ext4 -F "$dev_boot"
        [[ $(blockdev --getsize64 "$dev_boot") -eq $((512 * 1024 * 1024)) ]]
    fi
    [[ $(blockdev --getsize64 "$dev_os") -eq $(((p_root_initial_end - p_root_start) * 1048576)) ]]
    root_uuid=$(blkid -s UUID -o value "$dev_os")
    mkdir -p "$test_dir/os"
    mount "$dev_os" "$test_dir/os"
    echo root-persistence >"$test_dir/os/root-probe"
    umount "$test_dir/os"
    cp_finish_partitions
    [[ $(blockdev --getsize64 "$dev_os") -eq $(((p_root_end - p_root_start) * 1048576)) ]]
    [[ $(blkid -s UUID -o value "$dev_os") == "$root_uuid" ]]
    if [[ -n "$p_data_plan" ]]; then
        while IFS=: read -r num point start end; do
            dev=/dev/$(xda "$num")
            [[ $(blkid -s TYPE -o value "$dev") == ext4 ]]
            [[ $(blockdev --getsize64 "$dev") -eq $(((end - start) * 1048576)) ]]
        done <<<"$p_data_plan"
    else
        [[ ! -b /dev/$(xda "$p_installer_num") ]]
    fi
    mkdir -p "$test_dir/os"
    mount "$dev_os" "$test_dir/os"
    [[ $(cat "$test_dir/os/root-probe") == root-persistence ]]
    [[ $(df -B1 --output=size "$test_dir/os" | tail -1) -gt $(((p_root_end - p_root_start) * 1048576 - 1073741824)) ]]
    mkdir -p "$test_dir/os/boot"
    cp_mount_boot "$test_dir/os"
    if [[ "$mode" == efi ]]; then
        mkdir -p "$test_dir/os/boot/efi"
        mount "$dev_efi" "$test_dir/os/boot/efi"
    fi
    mkdir -p "$test_dir/os/etc"
    while IFS=: read -r dev point; do
        [[ -n "$dev" ]] || continue
        mkdir -p "$test_dir/os$point"
        chmod 750 "$test_dir/os$point"
        chown 1001:1002 "$test_dir/os$point"
        echo preserved-data >"$test_dir/os$point/probe"
        chmod 640 "$test_dir/os$point/probe"
        chown 1001:1002 "$test_dir/os$point/probe"
    done < <(cp_data_devices)
    cp_mount_data "$test_dir/os"
    echo kernel-probe >"$test_dir/os/boot/kernel-probe"
    echo '# generated in loop test' >"$test_dir/os/etc/fstab"
    cp_write_fstab "$test_dir/os"
    if [[ -n "$dev_boot" ]]; then grep -q ' /boot ext4 ' "$test_dir/os/etc/fstab"; fi
    while IFS=: read -r dev point; do
        [[ -n "$dev" ]] || continue
        [[ $(findmnt -n -o SOURCE --target "$test_dir/os$point") == "$dev" ]]
        [[ $(cat "$test_dir/os$point/probe") == preserved-data ]]
        [[ $(stat -c '%u:%g:%a' "$test_dir/os$point") == 1001:1002:750 ]]
        [[ $(stat -c '%u:%g:%a' "$test_dir/os$point/probe") == 1001:1002:640 ]]
        grep -Fxq "UUID=$(blkid -s UUID -o value "$dev") $point ext4 defaults 0 2" "$test_dir/os/etc/fstab"
    done < <(cp_data_devices)
    if [[ "$mode" == efi ]]; then
        [[ $(blkid -s TYPE -o value "$dev_efi") == vfat ]]
        cp_fix_efi_grub "$test_dir/os"
        grep -q -- "--set=root $(blkid -s UUID -o value "${dev_boot:-$dev_os}")" "$test_dir/os/boot/efi/EFI/ubuntu/grub.cfg"
    fi
    parted "$loop_device" -s unit MiB print
    umount -R "$test_dir/os"
    # Check actual persistence after unmount/remount, not only the mount table.
    while IFS=: read -r dev point; do
        [[ -n "$dev" ]] || continue
        mount "$dev" "$test_dir/os"
        [[ $(cat "$test_dir/os/probe") == preserved-data ]]
        [[ $(stat -c '%u:%g:%a' "$test_dir/os") == 1001:1002:750 ]]
        [[ $(stat -c '%u:%g:%a' "$test_dir/os/probe") == 1001:1002:640 ]]
        umount "$test_dir/os"
    done < <(cp_data_devices)
    if [[ -n "$dev_boot" ]]; then
        mount "$dev_boot" "$test_dir/os"
        [[ $(cat "$test_dir/os/kernel-probe") == kernel-probe ]]
        umount "$test_dir/os"
    fi
    losetup -d "$loop_device"
    loop_device=''
    rm -- "$image"
done
done
echo 'BIOS and UEFI loop-image tests passed (no OS boot performed).'
