#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared by the Bash entry point and Alpine ash installer. No work at source time.
# Variables distro/releasever/xda are provided by the upstream caller.
# shellcheck disable=SC2154
# shellcheck disable=SC2034
CUSTOM_PARTITION_API=1

# /configs is carried into Alpine sysroot by upstream's initramfs hook.
# Files placed only at initramfs / are discarded at switch_root.
cp_embed_installer() {
    local bundle=$1 initrd=$2
    mkdir -p "$initrd/configs"
    cp "$bundle/trans.sh" "$initrd/trans.sh"
    cp "$bundle/partition-layout.sh" "$initrd/configs/partition-layout.sh"
}

cp_fail() {
    echo "Custom partitions: $*" >&2
    return 1
}

# Integer sizes only; round decimal units UP to a MiB boundary.
cp_size_mib() {
    local value=$1 number factor
    case "$value" in
    '' | *[!A-Za-z0-9]*) cp_fail "Invalid size: $value"; return 1 ;;
    esac
    number=$(printf '%s' "$value" | sed -nE 's/^([1-9][0-9]*)(MiB|GiB|TiB|MB|GB|TB|M|G|T)$/\1/p')
    if [ -z "$number" ] || [ ${#number} -gt 9 ]; then
        cp_fail "Invalid size: $value"
        return 1
    fi
    case "$value" in
    *MiB | *M) factor=1048576 ;;
    *GiB | *G) factor=1073741824 ;;
    *TiB | *T) factor=1099511627776 ;;
    *MB) factor=1000000 ;;
    *GB) factor=1000000000 ;;
    *TB) factor=1000000000000 ;;
    esac
    # Keep every multiplication within signed 64-bit arithmetic; max 1 PiB.
    [ "$number" -le "$((1125899906842624 / factor))" ] || { cp_fail "Size too large: $value"; return 1; }
    echo "$(((number * factor + 1048575) / 1048576))"
}

cp_validate() {
    p_root=$(cp_size_mib "${part_root_size:-}") || return 1
    [ "$p_root" -ge 8192 ] || { cp_fail 'Root must be at least 8GiB.'; return 1; }
    p_boot=0
    if [ -n "${part_boot_size:-}" ] && [ "$part_boot_size" != 0 ]; then
        p_boot=$(cp_size_mib "$part_boot_size") || return 1
        [ "$p_boot" -ge 512 ] || { cp_fail '/boot must be at least 512MiB.'; return 1; }
    fi
    p_efi=$(cp_size_mib "${part_efi_size:-512MiB}") || return 1
    [ "$p_efi" -ge 100 ] || { cp_fail 'EFI partition must be at least 100MiB.'; return 1; }
    p_data=0
    case "${part_data_size:-}" in
    '')
        [ -z "${part_data_mount:-}" ] || { cp_fail '--data-mount requires --data-size.'; return 1; }
        ;;
    rest) p_data=rest ;;
    *)
        p_data=$(cp_size_mib "$part_data_size") || return 1
        [ "$p_data" -ge 1024 ] || { cp_fail 'Data partition must be at least 1GiB.'; return 1; }
        ;;
    esac
    if [ "$p_data" != 0 ]; then
        part_data_mount=${part_data_mount:-/data}
        # Restrict to ordinary absolute paths, safe for cmdline and fstab.
        printf '%s\n' "$part_data_mount" | grep -Eq '^/([A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+$' || {
            cp_fail 'Invalid data mount path.'; return 1;
        }
        case "$part_data_mount/" in
        /boot/* | /etc/* | /usr/* | /bin/* | /sbin/* | /lib/* | /lib64/* | /dev/* | /proc/* | /sys/* | /run/* | /tmp/* | /root/* | /var/* | /lost+found/*)
            cp_fail 'Data mount must not replace a system directory.'; return 1 ;;
        esac
    fi
}

cp_check_target() {
    # reinstall.sh initializes basearch, but Alpine trans.sh does not.
    local target_arch=${basearch:-$(uname -m)}
    if [ "$distro" != ubuntu ] || [ "$releasever" != 24.04 ] ||
        [ "$target_arch" != x86_64 ] || [ "${cloud_image:-0}" != 1 ]; then
        cp_fail 'Supported target: Ubuntu 24.04 x86_64 cloud-image installation only.'
        return 1
    fi
    cp_validate
}

# Pure planner. All endpoints are exclusive MiB boundaries; reserve 1MiB for GPT.
# The installer occupies the tail temporarily. Data is created only after it is
# removed, so "rest" also reclaims ALL of that temporary space.
cp_plan() {
    local disk_mib=$1 mode=$2 installer_mib=$3 cursor num
    cp_validate || return 1
    case "$disk_mib:$installer_mib" in *[!0-9:]*) cp_fail 'Invalid disk/installer capacity.'; return 1 ;; esac
    if [ -z "$disk_mib" ] || [ -z "$installer_mib" ] ||
        [ ${#disk_mib} -gt 10 ] || [ ${#installer_mib} -gt 10 ] ||
        [ "$disk_mib" -le 0 ] || [ "$installer_mib" -le 0 ]; then
        cp_fail 'Invalid capacity.'
        return 1
    fi
    p_disk_end=$((disk_mib - 1))
    p_installer_start=$((p_disk_end - installer_mib))
    p_mode=$mode
    case "$mode" in
    efi) cursor=$((1 + p_efi)) ;;
    bios)
        [ -z "${part_efi_size:-}" ] || { cp_fail '--efi-size is only valid in UEFI mode.'; return 1; }
        cursor=2 ;;
    *) cp_fail 'Boot mode must be efi or bios.'; return 1 ;;
    esac
    num=2
    p_boot_num=0
    p_boot_start=$cursor
    p_boot_end=$((cursor + p_boot))
    if [ "$p_boot" -gt 0 ]; then
        p_boot_num=$num
        num=$((num + 1))
        cursor=$p_boot_end
    fi
    p_root_num=$num
    p_root_start=$cursor
    p_root_end=$((cursor + p_root))
    p_installer_num=$((num + 1))
    p_data_num=$p_installer_num
    p_data_start=$p_root_end
    case "$p_data" in
    0) p_data_end=$p_data_start ;;
    rest) p_data_end=$p_disk_end ;;
    *) p_data_end=$((p_data_start + p_data)) ;;
    esac
    [ "$p_root_end" -le "$p_installer_start" ] || { cp_fail 'Disk cannot fit root, boot and temporary image storage.'; return 1; }
    [ "$p_data_end" -le "$p_disk_end" ] || { cp_fail 'Requested partitions exceed disk capacity.'; return 1; }
    if [ "$p_data" != 0 ]; then
        [ "$((p_data_end - p_data_start))" -ge 1024 ] || { cp_fail 'Less than 1GiB remains for data.'; return 1; }
    fi
}

cp_show_plan() {
    echo 'Custom GPT layout (MiB; end exclusive):'
    if [ "$p_mode" = efi ]; then
        echo "1 EFI /boot/efi 1 $((1 + p_efi)) fat32"
    else
        echo '1 BIOS-GRUB - 1 2 unformatted'
    fi
    if [ "$p_boot_num" -gt 0 ]; then
        echo "$p_boot_num BOOT /boot $p_boot_start $p_boot_end ext4"
    fi
    echo "$p_root_num ROOT / $p_root_start $p_root_end ext4"
    if [ "$p_data" != 0 ]; then
        echo "$p_data_num DATA $part_data_mount $p_data_start $p_data_end ext4 (created after installer removal)"
    fi
    echo "$p_installer_num INSTALLER temporary $p_installer_start $p_disk_end ext4 (removed after copying)"
}

# Runtime functions below use upstream helpers and run only inside Alpine.
cp_prepare() {
    local disk_bytes installer_size mode
    cp_check_target || return 1
    if is_efi; then mode=efi; else mode=bios; fi
    disk_bytes=$(get_disk_size "/dev/$xda") || return 1
    installer_size=$(get_cloud_image_part_size) || return 1
    installer_size=$(cp_size_mib "$installer_size") || return 1
    cp_plan "$((disk_bytes / 1048576))" "$mode" "$installer_size" || return 1
    cp_show_plan
}

cp_create() {
    # cp_prepare has finished BEFORE the first destructive command.
    apk add parted e2fsprogs wipefs
    if is_efi; then apk add dosfstools; fi
    wipefs -a -f "/dev/$xda"
    parted "/dev/$xda" -s -- mklabel gpt
    dev_efi='' dev_grub='' dev_boot='' dev_data=''
    if is_efi; then
        parted "/dev/$xda" -s -- mkpart EFI fat32 1MiB "$((1 + p_efi))MiB" set 1 esp on
        dev_efi="/dev/$(xda 1)"
    else
        parted "/dev/$xda" -s -- mkpart BIOS-GRUB 1MiB 2MiB set 1 bios_grub on
        dev_grub="/dev/$(xda 1)"
    fi
    if [ "$p_boot_num" -gt 0 ]; then
        parted "/dev/$xda" -s -- mkpart BOOT ext4 "${p_boot_start}MiB" "${p_boot_end}MiB"
        dev_boot="/dev/$(xda "$p_boot_num")"
    fi
    parted "/dev/$xda" -s -- mkpart ROOT ext4 "${p_root_start}MiB" "${p_root_end}MiB"
    dev_os="/dev/$(xda "$p_root_num")"
    parted "/dev/$xda" -s -- mkpart INSTALLER ext4 "${p_installer_start}MiB" "${p_disk_end}MiB"
    dev_installer="/dev/$(xda "$p_installer_num")"
    update_part
    if [ -n "$dev_efi" ]; then mkfs.fat -F 32 "$dev_efi"; fi
    if [ -n "$dev_grub" ]; then fill_zero "$dev_grub"; fi
    # Root is formatted by the Ubuntu image's own mkfs.ext4 later.
    # A separate boot filesystem is also formatted by Ubuntu's mkfs later.
    mkfs.ext4 -F -L INSTALLER "$dev_installer"
}

cp_mount_boot() {
    local os_dir=${1:-/os}
    if [ -n "${dev_boot:-}" ]; then
        mkdir -p "$os_dir/boot"
        mount "$dev_boot" "$os_dir/boot"
    fi
}

cp_finish_partitions() {
    parted "/dev/$xda" -s -- rm "$p_installer_num"
    update_part
    if [ "$p_data" != 0 ]; then
        parted "/dev/$xda" -s -- mkpart DATA ext4 "${p_data_start}MiB" "${p_data_end}MiB"
        dev_data="/dev/$(xda "$p_data_num")"
        update_part
        mkfs.ext4 -F -L DATA "$dev_data"
    fi
    # Deliberately do NOT call the upstream grow-to-disk-end helper.
}

cp_fstab_line() {
    local uuid
    uuid=$(lsblk -dnro UUID "$1")
    [ -n "$uuid" ] || { cp_fail "Missing UUID for $1"; return 1; }
    printf 'UUID=%s %s %s %s 0 %s\n' "$uuid" "$2" "$3" "$4" "$5"
}

cp_write_fstab() {
    local os_dir=$1
    awk -v data="${part_data_mount:-}" '
        $2 != "/" && $2 != "/boot" && $2 != "/boot/efi" && (data == "" || $2 != data)
    ' "$os_dir/etc/fstab" >"$os_dir/etc/fstab.custom"
    cp_fstab_line "$dev_os" / ext4 defaults 1 >>"$os_dir/etc/fstab.custom" || return 1
    if [ -n "${dev_boot:-}" ]; then
        cp_fstab_line "$dev_boot" /boot ext4 defaults 2 >>"$os_dir/etc/fstab.custom" || return 1
    fi
    if [ -n "${dev_efi:-}" ]; then
        cp_fstab_line "$dev_efi" /boot/efi vfat umask=0077 2 >>"$os_dir/etc/fstab.custom" || return 1
    fi
    if [ -n "${dev_data:-}" ]; then
        cp_fstab_line "$dev_data" "$part_data_mount" ext4 defaults 2 >>"$os_dir/etc/fstab.custom" || return 1
    fi
    mv "$os_dir/etc/fstab.custom" "$os_dir/etc/fstab"
}

cp_mount_data() {
    local os_dir=${1:-/os} staging
    staging=$os_dir.custom-data
    if [ -n "${dev_data:-}" ]; then
        # Keep existing files (e.g. when /home is selected) on the new filesystem.
        # Reject symlinks instead of following one outside the new root.
        local path=$os_dir component rest=${part_data_mount#/}
        while [ -n "$rest" ]; do
            component=${rest%%/*}
            path=$path/$component
            [ ! -L "$path" ] || { cp_fail "Symlink in data mount path: $path"; return 1; }
            case "$rest" in */*) rest=${rest#*/} ;; *) rest= ;; esac
        done
        mkdir -p "$os_dir$part_data_mount" "$staging"
        mount "$dev_data" "$staging"
        cp -a "$os_dir$part_data_mount/." "$staging/"
        # Leave underlying files intact until reboot rather than deleting user paths.
        umount "$staging"
        rmdir "$staging"
        mount "$dev_data" "$os_dir$part_data_mount"
    fi
}

cp_fix_efi_grub() {
    local os_dir=$1 boot_dev=${dev_boot:-$dev_os} prefix=/boot/grub uuid
    [ -z "${dev_boot:-}" ] || prefix=/grub
    uuid=$(lsblk -dnro UUID "$boot_dev")
    [ -n "$uuid" ] || { cp_fail 'Missing boot filesystem UUID.'; return 1; }
    mkdir -p "$os_dir/boot/efi/EFI/ubuntu"
    cat >"$os_dir/boot/efi/EFI/ubuntu/grub.cfg" <<EOF
search --no-floppy --fs-uuid --set=root $uuid
set prefix=(\$root)$prefix
configfile \$prefix/grub.cfg
EOF
}
