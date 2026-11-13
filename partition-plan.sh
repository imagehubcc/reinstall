#!/bin/sh
# Offline preview only. Never opens a disk or changes boot configuration.
set -eu
. "$(dirname "$0")/partition-layout.sh"
disk_size='' boot_mode='' installer_size=2GiB
usage() {
    echo 'Usage: sh partition-plan.sh --disk-size 1TiB --boot-mode efi|bios --root-size 300GiB [--boot-size 2GiB] [--efi-size 512MiB] [--data-size rest|SIZE] [--data-mount /data] [--installer-size 2GiB]'
}
while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help) usage; exit 0 ;;
    --disk-size | --boot-mode | --installer-size | --root-size | --boot-size | --efi-size | --data-size | --data-mount)
        [ "$#" -ge 2 ] || { usage >&2; exit 1; }
        case "$1" in
        --disk-size) disk_size=$2 ;;
        --boot-mode) boot_mode=$2 ;;
        --installer-size) installer_size=$2 ;;
        --root-size) part_root_size=$2 ;;
        --boot-size) part_boot_size=$2 ;;
        --efi-size) part_efi_size=$2 ;;
        --data-size) part_data_size=$2 ;;
        --data-mount) part_data_mount=$2 ;;
        esac
        shift 2 ;;
    *) cp_fail "Unknown option: $1"; exit 1 ;;
    esac
done
disk_mib=$(cp_size_mib "$disk_size")
installer_mib=$(cp_size_mib "$installer_size")
cp_plan "$disk_mib" "$boot_mode" "$installer_mib"
cp_show_plan
echo 'Preview only. Actual installation recalculates using the detected disk and image sizes.'
