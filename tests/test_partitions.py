#!/usr/bin/env python3
"""Offline tests: execute real shell functions; mock every disk-writing command."""
import os
from pathlib import Path
import shlex
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHELL = shlex.split(os.environ.get('PARTITION_SHELL', 'bash'))
TRANS = (ROOT / 'trans.sh').read_text(encoding='utf-8').split('# 脚本入口')[0]
ENTRY = (ROOT / 'reinstall.sh').read_text(encoding='utf-8')
FORMATTER_MOCKS = '''
mock_bin=$(mktemp -d)
trap 'rm -rf "$mock_bin"' EXIT
for fs in fat ext4; do
    cat >"$mock_bin/mkfs.$fs" <<'MOCK'
#!/bin/sh
echo "FORMAT $*"
MOCK
    chmod +x "$mock_bin/mkfs.$fs"
done
PATH="$mock_bin:$PATH"
'''


def run(code, *, trans=False):
    prefix = (TRANS + '\n') if trans else 'set -e\n'
    result = subprocess.run(
        SHELL + ['-s'], input=(prefix + '. ./partition-layout.sh\n' + code).encode('utf-8'),
        cwd=ROOT, capture_output=True,
    )
    result.stdout = result.stdout.decode('utf-8', errors='replace').replace('\r\n', '\n')
    result.stderr = result.stderr.decode('utf-8', errors='replace').replace('\r\n', '\n')
    return result


class Partitions(unittest.TestCase):
    def ok(self, code, expected=None, **kwargs):
        result = run(code, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        if expected is not None:
            self.assertEqual(result.stdout.strip(), expected)
        return result.stdout

    def bad(self, code, message=None, **kwargs):
        result = run(code, **kwargs)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        if message:
            self.assertIn(message, result.stderr)
        return result

    def test_units(self):
        for value, mib in [('300GiB', 307200), ('300GB', 286103), ('2TiB', 2097152),
                           ('512MiB', 512), ('1TB', 953675), ('8G', 8192), ('9MB', 9)]:
            with self.subTest(value=value):
                self.ok(f'cp_size_mib {value}', str(mib))

    def test_invalid_sizes(self):
        for value in ['', '0GiB', '-1GiB', '1.5GiB', '08GiB', '1', '1g',
                      '999999999TiB', '1GiB;id', '1GiB\n2GiB', "8GiB\n';id", '8GiB\n']:
            with self.subTest(value=value):
                self.bad('cp_size_mib ' + shlex.quote(value))

    def test_efi_rest_layout(self):
        self.ok('''
part_root_size=300GiB part_boot_size=2GiB part_data_size=rest
cp_plan 1048576 efi 2048
echo "$p_boot_num:$p_root_num:$p_installer_num:$p_root_start:$p_root_end:$p_data_end:$part_data_mount"
''', '2:3:4:2561:309761:1048575:/data')

    def test_root_size_is_fully_configurable(self):
        for size, mib in [('8GiB', 8192), ('64GiB', 65536), ('100GiB', 102400),
                          ('500GiB', 512000), ('900GB', 858307)]:
            with self.subTest(size=size):
                self.ok(f'''part_root_size={size} part_data_size=rest
cp_plan 1048576 efi 2048
echo "$((p_root_end - p_root_start))"
''', str(mib))

    def test_bios_no_boot_fixed_data(self):
        self.ok('''
part_root_size=300GiB part_data_size=100GiB
cp_plan 1048576 bios 2048
echo "$p_boot_num:$p_root_num:$p_installer_num:$p_root_start:$p_root_end:$p_data_end"
''', '0:2:3:2:307202:409602')

    def test_no_data_and_no_boot(self):
        self.ok('''
part_root_size=8GiB part_boot_size=0
cp_plan 16384 efi 2048
echo "$p_data:$p_boot_num:$p_root_num:$p_root_end:$p_data_end"
''', '0:0:2:8705:8705')

    def test_rejects_insufficient_disk(self):
        self.bad('part_root_size=300GiB; cp_plan 307200 efi 2048', 'temporary image')
        self.bad('part_root_size=8GiB part_data_size=20GiB; cp_plan 16384 bios 2048', 'exceed disk')
        self.bad('part_root_size=8GiB part_data_size=rest; cp_plan 9000 efi 100', '1GiB remains')

    def test_validates_roles(self):
        for options in ['part_root_size=7GiB', 'part_root_size=8GiB part_boot_size=100MiB',
                        'part_root_size=8GiB part_efi_size=50MiB',
                        'part_root_size=8GiB part_data_size=500MiB',
                        'part_root_size=8GiB part_data_mount=/data']:
            self.bad(options + '; cp_validate')
        self.bad('part_root_size=8GiB part_efi_size=512MiB; cp_plan 16384 bios 2048', 'UEFI')

    def test_mount_path_validation(self):
        for path in ['/', '/boot', '/boot/efi', '/etc/a', '/var/lib', '/root', '/usr',
                     '/dev', '/sys', '/data/../etc', '//data', '/data/', '/data x',
                     "/data'", '/data;id', 'data']:
            with self.subTest(path=path):
                self.bad('part_root_size=8GiB part_data_size=rest part_data_mount=' +
                         shlex.quote(path) + '; cp_validate')
        for path in ['/data', '/srv/storage', '/home']:
            self.ok(f'part_root_size=8GiB part_data_size=rest part_data_mount={path}; cp_validate')

    def test_target_gate(self):
        self.ok('distro=ubuntu releasever=24.04 basearch=x86_64 cloud_image=1 part_root_size=8GiB; cp_check_target')
        for target in ['distro=debian releasever=12 basearch=x86_64 cloud_image=1',
                       'distro=ubuntu releasever=22.04 basearch=x86_64 cloud_image=1',
                       'distro=ubuntu releasever=24.04 basearch=aarch64 cloud_image=1',
                       'distro=ubuntu releasever=24.04 basearch=x86_64 cloud_image=0']:
            self.bad(target + ' part_root_size=8GiB; cp_check_target', 'Supported target')

    def test_alpine_runtime_without_basearch(self):
        self.ok('''
unset basearch
uname() { echo x86_64; }
distro=ubuntu releasever=24.04 cloud_image=1 part_root_size=64GiB
cp_check_target
''')
        self.bad('''
unset basearch
uname() { echo aarch64; }
distro=ubuntu releasever=24.04 cloud_image=1 part_root_size=64GiB
cp_check_target
''', 'Supported target')

    def test_custom_validation_runs_after_rescue_ssh(self):
        runtime = (ROOT / 'trans.sh').read_text(encoding='utf-8').split('# 脚本入口', 1)[1]
        ssh_ready = runtime.rindex('setup-sshd')
        validation = runtime.index("cp_check_target || error_and_exit")
        self.assertLess(ssh_ready, validation)
        self.assertLess(validation, runtime.index('# 正式运行重装'))

    def test_module_survives_actual_switch_root_transfer_hook(self):
        # Execute the real upstream transfer loop, with fixture source paths.
        hook = ENTRY.split('        for dir in /configs /custom_drivers; do', 1)[1].split('\nEOF', 1)[0]
        hook = 'for dir in "$initrd/configs" "$initrd/custom_drivers"; do' + hook
        hook = hook.replace('\\$', '$')
        runtime = (ROOT / 'trans.sh').read_text(encoding='utf-8').split('# 脚本入口', 1)[1]
        self.assertIn('. /configs/partition-layout.sh', runtime)
        self.assertIn('cp_embed_installer "$custom_bundle_dir" "$initrd_dir"', ENTRY)
        self.ok('''
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
initrd=$tmp/initrd sysroot=$tmp/sysroot
mkdir -p "$initrd" "$sysroot"
cp_embed_installer . "$initrd"
[ -f "$initrd/trans.sh" ]
''' + hook + '''
[ -f "$sysroot/configs/partition-layout.sh" ]
cmp ./partition-layout.sh "$sysroot/configs/partition-layout.sh"
unset CUSTOM_PARTITION_API
. "$sysroot/configs/partition-layout.sh"
[ "$CUSTOM_PARTITION_API" = 1 ]
''')

    def test_capacity_validation_precedes_wipe(self):
        result = self.bad('''
custom_partition=1 distro=ubuntu releasever=24.04 basearch=x86_64 cloud_image=1 part_root_size=300GiB xda=vda
get_disk_size() { echo 10737418240; }
get_cloud_image_part_size() { echo 2GiB; }
is_efi() { return 0; }
error_and_exit() { echo "$*" >&2; exit 9; }
cp_create() { echo UNSAFE_WRITE; }
create_part
''', 'disk has not been wiped', trans=True)
        self.assertNotIn('UNSAFE_WRITE', result.stdout)

    def test_create_and_finish_roles(self):
        trace = self.ok(FORMATTER_MOCKS + '''
part_root_size=300GiB part_boot_size=2GiB part_data_size=rest xda=nvme0n1
cp_plan 1048576 efi 2048
is_efi() { return 0; }
is_digit() { case "$1" in *[!0-9]*) return 1;; esac; }
_xda() { echo "${xda}p$1"; }
apk() { :; }
update_part() { :; }
wipefs() { echo "WIPE $*"; }
parted() { echo "PARTED $*"; }
cp_create
echo "DEVICES $dev_os $dev_boot $dev_installer"
cp_finish_partitions
''', trans=True)
        self.assertIn('DEVICES /dev/nvme0n1p3 /dev/nvme0n1p2 /dev/nvme0n1p4', trace)
        self.assertIn('PARTED /dev/nvme0n1 -s -- rm 4', trace)
        self.assertIn('mkpart DATA ext4 309761MiB 1048575MiB', trace)
        self.assertNotIn('resizepart', trace)
        self.assertLess(trace.index('rm 4'), trace.index('mkpart DATA'))

    def test_original_partition_path(self):
        trace = self.ok(FORMATTER_MOCKS + '''
custom_partition=0 distro=ubuntu cloud_image=1 xda=vda
info() { :; }
apk() { :; }
is_use_cloud_image() { return 0; }
is_efi() { return 0; }
get_cloud_image_part_size() { echo 2GiB; }
update_part() { :; }
xda() { echo "vda$1"; }
wipefs() { echo "WIPE $*"; }
parted() { echo "PARTED $*"; }
cp_prepare() { echo WRONG_CUSTOM_PATH; exit 10; }
create_part
''', trans=True)
        self.assertNotIn('WRONG_CUSTOM_PATH', trace)
        self.assertIn('ext4 -2GiB 100%', trace)

    @unittest.skipIf('ash' in SHELL, 'Entry CLI uses Bash, not the Alpine runtime shell')
    def test_cli_parser(self):
        opts = ENTRY.split('# 整理参数\n', 1)[1].split('# 第一遍扫描', 1)[0]
        scan = ENTRY.split('# 第二遍扫描，处理参数\n', 1)[1].split('# 检查必须的参数', 1)[0]
        self.ok('''
set -- ubuntu 24.04 --root-size 300GiB --boot-size 2GiB --efi-size 512MiB --data-size rest --data-mount /srv/data
''' + opts + scan + '''
cp_validate
echo "$custom_partition:$part_root_size:$part_boot_size:$part_efi_size:$part_data_size:$part_data_mount"
''', '1:300GiB:2GiB:512MiB:rest:/srv/data')

    def test_fstab_idempotence_and_grub(self):
        self.ok('''
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/etc"
printf '# keep comment\nLABEL=old / ext4 defaults 0 1\nLABEL=oldboot /boot ext4 defaults 0 2\nLABEL=oldesp /boot/efi vfat defaults 0 0\n/swapfile none swap sw 0 0\n' >"$tmp/etc/fstab"
dev_os=/dev/vda3 dev_boot=/dev/vda2 dev_efi=/dev/vda1 dev_data=/dev/vda4 part_data_mount=/data
lsblk() { case "$*" in *vda1) echo EFI_UUID;; *vda2) echo BOOT_UUID;; *vda3) echo ROOT_UUID;; *vda4) echo DATA_UUID;; esac; }
cp_write_fstab "$tmp"
cp_write_fstab "$tmp"
[ "$(grep -c ' /boot ' "$tmp/etc/fstab")" = 1 ]
grep -q '^UUID=ROOT_UUID / ext4 defaults 0 1$' "$tmp/etc/fstab"
grep -q '^UUID=DATA_UUID /data ext4 defaults 0 2$' "$tmp/etc/fstab"
grep -q '^# keep comment$' "$tmp/etc/fstab"
grep -q '^/swapfile' "$tmp/etc/fstab"
! grep -q 'LABEL=old' "$tmp/etc/fstab"
cp_fix_efi_grub "$tmp"
grep -q -- '--set=root BOOT_UUID' "$tmp/boot/efi/EFI/ubuntu/grub.cfg"
grep -Fq 'set prefix=($root)/grub' "$tmp/boot/efi/EFI/ubuntu/grub.cfg"
dev_boot=
cp_fix_efi_grub "$tmp"
grep -q -- '--set=root ROOT_UUID' "$tmp/boot/efi/EFI/ubuntu/grub.cfg"
grep -Fq 'set prefix=($root)/boot/grub' "$tmp/boot/efi/EFI/ubuntu/grub.cfg"
''')

    @unittest.skipIf('ash' in SHELL, 'Entry cmdline builder uses Bash')
    def test_entrypoint_cmdline(self):
        fn = ENTRY.split('build_extra_cmdline() {', 1)[1].split('\necho_tmp_ttys()', 1)[0]
        self.ok('''
is_need_quote() { return 1; }
is_grub_dir_linked() { return 1; }
custom_partition=1 part_root_size=300GiB part_data_size=rest part_data_mount=/data
build_extra_cmdline() {''' + fn + '''
build_extra_cmdline
case "$extra_cmdline" in *"extra_custom_partition=1"*"extra_part_root_size=300GiB"*"extra_part_data_size=rest"*"extra_part_data_mount=/data"*) :;; *) exit 1;; esac
''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
