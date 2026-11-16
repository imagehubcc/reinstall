#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared by the Bash entry point and Alpine ash installer. No work at source time.
# Variables distro/releasever/xda are provided by the upstream caller.
# shellcheck disable=SC2154
# shellcheck disable=SC2034
CUSTOM_PARTITION_API=2

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

# Canonical list: fixed-size partitions first, one optional rest partition last.
# Comma and colon are not allowed in mount paths, so no eval/word splitting is used.
cp_add_data() {
    local size=$1 point=$2 previous remaining old_point
    printf '%s\n' "$point" | grep -Eq '^/([A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+$' || {
        cp_fail 'Invalid data mount path.'; return 1;
    }
    case "$point/" in
    /boot/* | /etc/* | /usr/* | /bin/* | /sbin/* | /lib/* | /lib64/* | /dev/* | /proc/* | /sys/* | /run/* | /tmp/* | /root/* | /var/* | /lost+found/*)
        cp_fail 'Data mount must not replace a system directory.'; return 1 ;;
    esac
    remaining=$p_data_specs
    if [ -n "$p_data_rest_mount" ]; then remaining="${remaining:+$remaining,}rest:$p_data_rest_mount"; fi
    while [ -n "$remaining" ]; do
        previous=${remaining%%,*} old_point=${previous#*:}
        case "$point/" in "$old_point/"*) cp_fail 'Duplicate or nested data mount points.'; return 1 ;; esac
        case "$old_point/" in "$point/"*) cp_fail 'Duplicate or nested data mount points.'; return 1 ;; esac
        case "$remaining" in *,*) remaining=${remaining#*,} ;; *) remaining='' ;; esac
    done
    if [ "$size" = rest ]; then
        [ -z "$p_data_rest_mount" ] || { cp_fail 'Only one data partition may use rest.'; return 1; }
        p_data_rest_mount=$point
    else
        size=$(cp_size_mib "$size") || return 1
        [ "$size" -ge 1024 ] || { cp_fail 'Data partition must be at least 1GiB.'; return 1; }
        p_data_fixed=$((p_data_fixed + size))
        p_data_specs="${p_data_specs:+$p_data_specs,}$size:$point"
    fi
    p_data_count=$((p_data_count + 1))
}

cp_validate() {
    # Infer only omitted values; explicit competing "rest" requests are errors.
    case "${part_root_size:-}" in
    '' | rest) p_root=rest ;;
    *)
        p_root=$(cp_size_mib "$part_root_size") || return 1
        [ "$p_root" -ge 8192 ] || { cp_fail 'Root must be at least 8GiB.'; return 1; }
        ;;
    esac
    p_boot=0
    if [ -n "${part_boot_size:-}" ] && [ "$part_boot_size" != 0 ]; then
        p_boot=$(cp_size_mib "$part_boot_size") || return 1
        [ "$p_boot" -ge 512 ] || { cp_fail '/boot must be at least 512MiB.'; return 1; }
    fi
    p_efi=$(cp_size_mib "${part_efi_size:-512MiB}") || return 1
    [ "$p_efi" -ge 100 ] || { cp_fail 'EFI partition must be at least 100MiB.'; return 1; }
    p_data_specs='' p_data_fixed=0 p_data_rest_mount='' p_data_count=0
    local remaining item size point
    if [ -n "${part_data_specs:-}" ]; then
        [ -z "${part_data_size:-}${part_data_mount:-}" ] || { cp_fail 'Do not mix paired --data-size SIZE /PATH with legacy --data-size/--data-mount.'; return 1; }
        remaining=$part_data_specs
        case "$remaining" in *,) cp_fail 'Invalid data partition list.'; return 1 ;; esac
        while [ -n "$remaining" ]; do
            item=${remaining%%,*}
            case "$item" in *:*) : ;; *) cp_fail 'Each data partition needs SIZE and /PATH.'; return 1 ;; esac
            size=${item%%:*} point=${item#*:}
            cp_add_data "$size" "$point" || return 1
            case "$remaining" in *,*) remaining=${remaining#*,} ;; *) remaining='' ;; esac
        done
    else
        case "${part_data_size:-}" in
        '')
            if [ -n "${part_data_mount:-}" ]; then cp_add_data rest "$part_data_mount" || return 1; fi
            ;;
        0) [ -z "${part_data_mount:-}" ] || { cp_fail '--data-size 0 conflicts with --data-mount.'; return 1; } ;;
        *) cp_add_data "$part_data_size" "${part_data_mount:-/data}" || return 1 ;;
        esac
        if [ "$p_data_count" -gt 0 ]; then part_data_mount=${part_data_mount:-/data}; fi
    fi
    p_data=$p_data_fixed
    if [ -n "$p_data_rest_mount" ]; then
        p_data=rest
        if [ "$p_root" = rest ]; then
            if [ -z "${part_root_size:-}" ]; then
                cp_fail 'Data uses rest: specify --root-size SIZE to set the root partition size.'
            else
                cp_fail 'Root and data cannot both use rest.'
            fi
            return 1
        fi
        p_data_specs="${p_data_specs:+$p_data_specs,}rest:$p_data_rest_mount"
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
# The installer occupies the tail temporarily. After copying, remove it before
# growing root and creating data, so either role can reclaim temporary space.
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
    p_root_grow=0
    if [ "$p_root" = rest ]; then
        p_root_end=$((p_disk_end - p_data_fixed))
        [ "$((p_root_end - p_root_start))" -ge 8192 ] || { cp_fail 'Less than 8GiB remains for root.'; return 1; }
        p_root_grow=1
    else
        p_root_end=$((cursor + p_root))
    fi
    # The initial root must not overlap the still-needed image storage.
    p_root_initial_end=$p_root_end
    if [ "$p_root_grow" = 1 ] && [ "$p_root_initial_end" -gt "$p_installer_start" ]; then
        p_root_initial_end=$p_installer_start
    fi
    p_installer_num=$((num + 1))
    p_data_num=$p_installer_num
    p_data_start=$p_root_end
    p_data_end=$p_root_end
    p_data_plan=''
    local remaining item size point start end
    remaining=$p_data_specs
    num=$p_data_num
    while [ -n "$remaining" ]; do
        item=${remaining%%,*} size=${item%%:*} point=${item#*:}
        start=$p_data_end
        if [ "$size" = rest ]; then end=$p_disk_end; else end=$((start + size)); fi
        [ "$end" -le "$p_disk_end" ] || { cp_fail 'Requested partitions exceed disk capacity.'; return 1; }
        [ "$((end - start))" -ge 1024 ] || { cp_fail 'Less than 1GiB remains for data.'; return 1; }
        [ "$num" -le 128 ] || { cp_fail 'Too many partitions for GPT.'; return 1; }
        p_data_plan="${p_data_plan:+$p_data_plan
}$num:$point:$start:$end"
        p_data_end=$end
        num=$((num + 1))
        case "$remaining" in *,*) remaining=${remaining#*,} ;; *) remaining='' ;; esac
    done
    if [ "$p_root_initial_end" -gt "$p_installer_start" ] ||
        [ "$((p_root_initial_end - p_root_start))" -lt 8192 ]; then
        cp_fail 'Disk cannot fit root, boot and temporary image storage (initial root needs 8GiB).'; return 1
    fi
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
    if [ "$p_root_initial_end" != "$p_root_end" ]; then
        echo "ROOT initially ends at ${p_root_initial_end}MiB; grows after installer removal"
    fi
    if [ -n "$p_data_plan" ]; then
        local num point start end
        while IFS=: read -r num point start end; do
            echo "$num DATA $point $start $end ext4 (created after installer removal)"
        done <<EOF
$p_data_plan
EOF
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
    parted "/dev/$xda" -s -- mkpart ROOT ext4 "${p_root_start}MiB" "${p_root_initial_end}MiB"
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
    if [ "$p_root_initial_end" != "$p_root_end" ]; then
        # Root is unmounted here. Preserve its UUID and copied contents.
        apk add e2fsprogs-extra
        local fsck_status=0
        e2fsck -f -p "$dev_os" || fsck_status=$?
        [ "$fsck_status" -le 1 ] || { cp_fail 'Root filesystem check failed; refusing to grow.'; return 1; }
        parted "/dev/$xda" -s -- resizepart "$p_root_num" "${p_root_end}MiB"
        update_part
        resize2fs "$dev_os"
    fi
    if [ -n "$p_data_plan" ]; then
        local num point start end dev label
        while IFS=: read -r num point start end; do
            label=DATA
            [ "$num" = "$p_data_num" ] || label=DATA$num
            parted "/dev/$xda" -s -- mkpart "$label" ext4 "${start}MiB" "${end}MiB"
            dev="/dev/$(xda "$num")"
            [ "$num" != "$p_data_num" ] || dev_data=$dev
            update_part
            mkfs.ext4 -F -L "$label" "$dev"
        done <<EOF
$p_data_plan
EOF
    fi
    # Never grow a fixed root or extend root over a requested data partition.
}

cp_fstab_line() {
    local uuid
    uuid=$(lsblk -dnro UUID "$1")
    [ -n "$uuid" ] || { cp_fail "Missing UUID for $1"; return 1; }
    printf 'UUID=%s %s %s %s 0 %s\n' "$uuid" "$2" "$3" "$4" "$5"
}

# Map the validated layout to devices; fallback keeps legacy single-device callers.
cp_data_devices() {
    local num point start end
    if [ -n "${p_data_plan:-}" ]; then
        while IFS=: read -r num point start end; do
            printf '/dev/%s:%s\n' "$(xda "$num")" "$point"
        done <<EOF
$p_data_plan
EOF
    elif [ -n "${dev_data:-}" ]; then
        printf '%s:%s\n' "$dev_data" "$part_data_mount"
    fi
}

cp_write_fstab() {
    local os_dir=$1 devices dev point
    devices=$(cp_data_devices)
    awk -v data="$devices" '
        BEGIN {
            n=split(data, lines, "\n")
            for (i=1; i<=n; i++) { split(lines[i], fields, ":"); if (fields[2] != "") mounts[fields[2]]=1 }
        }
        $2 != "/" && $2 != "/boot" && $2 != "/boot/efi" && !($2 in mounts)
    ' "$os_dir/etc/fstab" >"$os_dir/etc/fstab.custom"
    cp_fstab_line "$dev_os" / ext4 defaults 1 >>"$os_dir/etc/fstab.custom" || return 1
    if [ -n "${dev_boot:-}" ]; then
        cp_fstab_line "$dev_boot" /boot ext4 defaults 2 >>"$os_dir/etc/fstab.custom" || return 1
    fi
    if [ -n "${dev_efi:-}" ]; then
        cp_fstab_line "$dev_efi" /boot/efi vfat umask=0077 2 >>"$os_dir/etc/fstab.custom" || return 1
    fi
    if [ -n "$devices" ]; then
        while IFS=: read -r dev point; do
            cp_fstab_line "$dev" "$point" ext4 defaults 2 >>"$os_dir/etc/fstab.custom" || return 1
        done <<EOF
$devices
EOF
    fi
    mv "$os_dir/etc/fstab.custom" "$os_dir/etc/fstab"
}

cp_check_data_paths() {
    local os_dir=$1 devices dev point path component rest
    devices=$(cp_data_devices)
    [ -n "$devices" ] || return 0
    # Check all paths before copying or mounting any partition.
    while IFS=: read -r dev point; do
        path=$os_dir rest=${point#/}
        while [ -n "$rest" ]; do
            component=${rest%%/*}
            path=$path/$component
            [ ! -L "$path" ] || { cp_fail "Symlink in data mount path: $path"; return 1; }
            [ ! -e "$path" ] || [ -d "$path" ] || { cp_fail "Data mount path is not a directory: $path"; return 1; }
            case "$rest" in */*) rest=${rest#*/} ;; *) rest= ;; esac
        done
    done <<EOF
$devices
EOF
}

cp_mount_data() {
    local os_dir=${1:-/os} staging devices dev point
    staging=$os_dir.custom-data
    devices=$(cp_data_devices)
    [ -n "$devices" ] || return 0
    cp_check_data_paths "$os_dir" || return 1
    while IFS=: read -r dev point; do
        mkdir -p "$os_dir$point" "$staging"
        mount "$dev" "$staging"
        # Preserve the new image's directory ownership/mode as well as contents.
        cp -a "$os_dir$point/." "$staging/"
        umount "$staging"
        rmdir "$staging"
        mount "$dev" "$os_dir$point"
    done <<EOF
$devices
EOF
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
