#!/bin/bash
sed -i -E '/^\.{3}$/d' /autoinstall.yaml
echo 'storage:' >>/autoinstall.yaml

# 禁用 swap
cat <<EOF >>/autoinstall.yaml
  swap:
    size: 0
EOF

# 是用 size 寻找分区，number 没什么用
# https://curtin.readthedocs.io/en/latest/topics/storage.html
size_os=$(lsblk -bn -o SIZE /dev/disk/by-label/os)

# 检查是否存在 boot 和 data 分区
has_boot=false
has_data=false
if [ -e /dev/disk/by-label/boot ]; then
    has_boot=true
    size_boot=$(lsblk -bn -o SIZE /dev/disk/by-label/boot)
fi
if [ -e /dev/disk/by-label/data ]; then
    has_data=true
    size_data=$(lsblk -bn -o SIZE /dev/disk/by-label/data)
fi

# shellcheck disable=SC2154
if parted "/dev/$xda" print | grep '^Partition Table' | grep gpt; then
    # efi
    if [ -e /dev/disk/by-label/efi ]; then
        size_efi=$(lsblk -bn -o SIZE /dev/disk/by-label/efi)
        cat <<EOF >>/autoinstall.yaml
  config:
    # disk
    - ptable: gpt
      path: /dev/$xda
      preserve: true
      type: disk
      id: disk-xda
    # efi 分区
    - device: disk-xda
      size: $size_efi
      number: 1
      preserve: true
      grub_device: true
      type: partition
      id: partition-efi
    - fstype: fat32
      volume: partition-efi
      type: format
      id: format-efi
EOF
        # boot 分区
        if [ "$has_boot" = true ]; then
            cat <<EOF >>/autoinstall.yaml
    # boot 分区
    - device: disk-xda
      size: $size_boot
      number: 2
      preserve: true
      type: partition
      id: partition-boot
    - fstype: ext4
      volume: partition-boot
      type: format
      id: format-boot
EOF
        fi
        # os 分区
        cat <<EOF >>/autoinstall.yaml
    # os 分区
    - device: disk-xda
      size: $size_os
      number: $([ "$has_boot" = true ] && echo 3 || echo 2)
      preserve: true
      type: partition
      id: partition-os
    - fstype: ext4
      volume: partition-os
      type: format
      id: format-os
EOF
        # data 分区
        if [ "$has_data" = true ]; then
            cat <<EOF >>/autoinstall.yaml
    # data 分区
    - device: disk-xda
      size: $size_data
      number: $([ "$has_boot" = true ] && echo 4 || echo 3)
      preserve: true
      type: partition
      id: partition-data
    - fstype: ext4
      volume: partition-data
      type: format
      id: format-data
EOF
        fi
        # mount
        cat <<EOF >>/autoinstall.yaml
    # mount
    - path: /
      device: format-os
      type: mount
      id: mount-os
EOF
        if [ "$has_boot" = true ]; then
            cat <<EOF >>/autoinstall.yaml
    - path: /boot
      device: format-boot
      type: mount
      id: mount-boot
EOF
        fi
        if [ "$has_data" = true ]; then
            cat <<EOF >>/autoinstall.yaml
    - path: /data
      device: format-data
      type: mount
      id: mount-data
EOF
        fi
        cat <<EOF >>/autoinstall.yaml
    - path: /boot/efi
      device: format-efi
      type: mount
      id: mount-efi
EOF
    else
        # bios > 2t
        size_biosboot=$(parted "/dev/$xda" unit b print | grep bios_grub | awk '{print $4}' | sed 's/B$//')
        cat <<EOF >>/autoinstall.yaml
  config:
    # disk
    - ptable: gpt
      path: /dev/$xda
      preserve: true
      grub_device: true
      type: disk
      id: disk-xda
    # biosboot 分区
    - device: disk-xda
      size: $size_biosboot
      number: 1
      preserve: true
      type: partition
      id: partition-biosboot
EOF
        # boot 分区
        if [ "$has_boot" = true ]; then
            cat <<EOF >>/autoinstall.yaml
    # boot 分区
    - device: disk-xda
      size: $size_boot
      number: 2
      preserve: true
      type: partition
      id: partition-boot
    - fstype: ext4
      volume: partition-boot
      type: format
      id: format-boot
EOF
        fi
        # os 分区
        cat <<EOF >>/autoinstall.yaml
    # os 分区
    - device: disk-xda
      size: $size_os
      number: $([ "$has_boot" = true ] && echo 3 || echo 2)
      preserve: true
      type: partition
      id: partition-os
    - fstype: ext4
      volume: partition-os
      type: format
      id: format-os
EOF
        # data 分区
        if [ "$has_data" = true ]; then
            cat <<EOF >>/autoinstall.yaml
    # data 分区
    - device: disk-xda
      size: $size_data
      number: $([ "$has_boot" = true ] && echo 4 || echo 3)
      preserve: true
      type: partition
      id: partition-data
    - fstype: ext4
      volume: partition-data
      type: format
      id: format-data
EOF
        fi
        # mount
        cat <<EOF >>/autoinstall.yaml
    # mount
    - path: /
      device: format-os
      type: mount
      id: mount-os
EOF
        if [ "$has_boot" = true ]; then
            cat <<EOF >>/autoinstall.yaml
    - path: /boot
      device: format-boot
      type: mount
      id: mount-boot
EOF
        fi
        if [ "$has_data" = true ]; then
            cat <<EOF >>/autoinstall.yaml
    - path: /data
      device: format-data
      type: mount
      id: mount-data
EOF
        fi
    fi
else
    # bios
    cat <<EOF >>/autoinstall.yaml
  config:
    # disk
    - ptable: msdos
      path: /dev/$xda
      preserve: true
      grub_device: true
      type: disk
      id: disk-xda
EOF
    # boot 分区
    if [ "$has_boot" = true ]; then
        cat <<EOF >>/autoinstall.yaml
    # boot 分区
    - device: disk-xda
      size: $size_boot
      number: 1
      preserve: true
      type: partition
      id: partition-boot
    - fstype: ext4
      volume: partition-boot
      type: format
      id: format-boot
EOF
    fi
    # os 分区
    cat <<EOF >>/autoinstall.yaml
    # os 分区
    - device: disk-xda
      size: $size_os
      number: $([ "$has_boot" = true ] && echo 2 || echo 1)
      preserve: true
      type: partition
      id: partition-os
    - fstype: ext4
      volume: partition-os
      type: format
      id: format-os
EOF
    # data 分区
    if [ "$has_data" = true ]; then
        cat <<EOF >>/autoinstall.yaml
    # data 分区
    - device: disk-xda
      size: $size_data
      number: $([ "$has_boot" = true ] && echo 3 || echo 2)
      preserve: true
      type: partition
      id: partition-data
    - fstype: ext4
      volume: partition-data
      type: format
      id: format-data
EOF
    fi
    # mount
    cat <<EOF >>/autoinstall.yaml
    # mount
    - path: /
      device: format-os
      type: mount
      id: mount-os
EOF
    if [ "$has_boot" = true ]; then
        cat <<EOF >>/autoinstall.yaml
    - path: /boot
      device: format-boot
      type: mount
      id: mount-boot
EOF
    fi
    if [ "$has_data" = true ]; then
        cat <<EOF >>/autoinstall.yaml
    - path: /data
      device: format-data
      type: mount
      id: mount-data
EOF
    fi
fi
echo ... >>/autoinstall.yaml
