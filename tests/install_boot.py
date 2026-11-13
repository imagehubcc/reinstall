#!/usr/bin/env python3
"""Destructive OS installation ONLY inside a new QEMU file-backed virtual disk.

The host is never a block-device target. Keys and guest disks stay in --work and
are not uploaded. Logs contain only the ephemeral test environment.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tarfile
import time
import urllib.request

IMAGE_ROOT = 'https://cloud-images.ubuntu.com/releases/noble/release/'
IMAGE_NAME = 'ubuntu-24.04-server-cloudimg-amd64.img'


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


class VM:
    def __init__(self, firmware, source, work):
        self.firmware, self.source, self.work = firmware, source.resolve(), work.resolve()
        self.process = None
        self.last_boot_id = None
        self.work.mkdir(parents=True, exist_ok=True)
        if (self.work / 'disk.qcow2').exists():
            raise RuntimeError('Use a fresh work directory; existing disks will not be overwritten')
        self.log = open(self.work / 'test.log', 'w', encoding='utf-8', buffering=1)
        self.key = self.work / 'test-key'
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]

    def note(self, text):
        print(text, flush=True)
        self.log.write(text + '\n')

    def ssh(self, command, data=None, timeout=60, check=True):
        args = ['ssh', '-i', self.key, '-p', self.port, '-o', 'BatchMode=yes',
                '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                '-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=5',
                '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=3',
                'root@127.0.0.1', command]
        result = subprocess.run([str(x) for x in args], input=data,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=timeout)
        output = result.stdout.decode('utf-8', errors='replace')
        if output:
            self.log.write(output)
        if check and result.returncode:
            raise RuntimeError(f'Guest command failed ({result.returncode}): {command}\n{output[-4000:]}')
        return result.returncode, output

    def wait(self, command, expected, seconds):
        deadline = time.monotonic() + seconds
        last_note = 0
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('QEMU exited unexpectedly; inspect serial.log')
            try:
                code, output = self.ssh(command, timeout=35, check=False)
                if code == 0 and expected in output:
                    return output
                if 'CI_INSTALL_FAILED' in output:
                    raise RuntimeError(output[-4000:])
            except (subprocess.TimeoutExpired, OSError):
                pass
            if time.monotonic() - last_note > 45:
                self.note(f'Waiting for {expected} ({int(deadline-time.monotonic())}s remaining)')
                last_note = time.monotonic()
            time.sleep(8)
        raise TimeoutError(f'Timed out waiting for {expected}; see test.log and serial.log')

    def setup(self):
        self.note(f'Preparing isolated {self.firmware} guest')
        run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', self.key])
        public_key = self.key.with_suffix('.pub').read_text().strip()
        # Unknown random password unlocks root for key authentication; never logged.
        password_hash = subprocess.check_output(
            ['openssl', 'passwd', '-6', secrets.token_hex(32)], text=True).strip()
        seed = {'hostname': 'reinstall-ci', 'manage_etc_hosts': True,
                'disable_root': False, 'ssh_pwauth': False,
                'users': [{'name': 'root', 'lock_passwd': False, 'passwd': password_hash,
                           'ssh_authorized_keys': [public_key]}]}
        (self.work / 'user-data').write_text('#cloud-config\n' + json.dumps(seed), encoding='utf-8')
        (self.work / 'meta-data').write_text('instance-id: reinstall-ci-' + secrets.token_hex(8) + '\n')
        run(['cloud-localds', self.work / 'seed.iso', self.work / 'user-data', self.work / 'meta-data'])
        with urllib.request.urlopen(IMAGE_ROOT + 'SHA256SUMS', timeout=60) as response:
            sums = response.read().decode()
        expected = next(line.split()[0] for line in sums.splitlines()
                        if line.split()[-1].lstrip('*') == IMAGE_NAME)
        image = self.work / 'base.img'
        with urllib.request.urlopen(IMAGE_ROOT + IMAGE_NAME, timeout=180) as response, image.open('wb') as dest:
            shutil.copyfileobj(response, dest)
        digest = hashlib.file_digest(image.open('rb'), 'sha256').hexdigest()
        if digest != expected:
            raise RuntimeError('Ubuntu image SHA256 mismatch')
        run(['qemu-img', 'convert', '-O', 'qcow2', image, self.work / 'disk.qcow2'])
        run(['qemu-img', 'resize', self.work / 'disk.qcow2', '32G'])
        if self.firmware == 'uefi':
            shutil.copyfile('/usr/share/OVMF/OVMF_VARS_4M.fd', self.work / 'vars.fd')
        archive = self.work / 'source.tar.gz'
        # Copy the complete tracked candidate, never .git, host credentials or work files.
        names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=self.source).decode().split('\0')
        with tarfile.open(archive, 'w:gz') as bundle:
            for name in filter(None, names):
                bundle.add(self.source / name, arcname=name, recursive=False)

    def start(self, seed):
        kvm = os.access('/dev/kvm', os.R_OK | os.W_OK)
        args = ['qemu-system-x86_64', '-machine', 'q35', '-m', '3072', '-smp', '2',
                '-accel', 'kvm' if kvm else 'tcg,thread=multi',
                '-cpu', 'host' if kvm else 'max',
                # This is a disposable test image, not a host block device.
                # Avoid emulated fsync latency; normal reboot/cold-start tests
                # still retain the image. Power-loss durability is not tested.
                '-drive', f'if=virtio,format=qcow2,cache=unsafe,file={self.work / "disk.qcow2"}',
                '-netdev', f'user,id=n1,hostfwd=tcp:127.0.0.1:{self.port}-:22',
                '-device', 'virtio-net-pci,netdev=n1,mac=52:54:00:12:34:56',
                '-display', 'none', '-serial', f'file:{self.work / "serial.log"}']
        if seed:
            args += ['-drive', f'file={self.work / "seed.iso"},format=raw,media=cdrom,readonly=on']
        if self.firmware == 'uefi':
            args += ['-drive', 'if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd',
                     '-drive', f'if=pflash,format=raw,file={self.work / "vars.fd"}']
        self.note('Starting QEMU with ' + ('KVM' if kvm else 'TCG'))
        self.qemu_log = open(self.work / 'qemu.log', 'ab')
        self.process = subprocess.Popen(args, stdout=self.qemu_log, stderr=subprocess.STDOUT)

    def prepare_install(self):
        self.wait('test -f /var/lib/cloud/instance/boot-finished && echo BOOTSTRAP_READY', 'BOOTSTRAP_READY', 900)
        self.ssh('mkdir -p /root/ci-source')
        self.ssh('tar -xzf - -C /root/ci-source', (self.work / 'source.tar.gz').read_bytes(), timeout=120)
        self.ssh('cat >/root/ci-source/ci-key.pub', self.key.with_suffix('.pub').read_bytes())
        script = r'''#!/bin/bash
set -euo pipefail
test "$(blockdev --getsize64 /dev/vda)" = 34359738368
test "$(findmnt -n -o SOURCE /)" = /dev/vda1
cd /root/ci-source
trap 'echo CI_INSTALL_FAILED' ERR
bash reinstall.sh ubuntu 24.04 --username root --ssh-key /root/ci-source/ci-key.pub \
  --target-disk /dev/vda --root-size 16GiB --boot-size 2GiB --data-size rest --hold 2
echo CI_PREPARE_DONE
'''
        self.ssh('cat >/root/ci-prepare.sh', script.encode())
        self.ssh('nohup bash /root/ci-prepare.sh >/root/ci-prepare.log 2>&1 </dev/null &')
        self.wait('cat /root/ci-prepare.log', 'CI_PREPARE_DONE', 900)
        self.note('Native entry point prepared; booting Alpine installer')
        self.ssh('nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 </dev/null &')
        time.sleep(15)
        output = self.wait(
            'test -f /etc/alpine-release && { tail -30 /reinstall.log; ' +
            'grep -iq "hold 2" /reinstall.log && echo CI_INSTALL_DONE; }',
            'CI_INSTALL_DONE', 2700)
        self.note(output[-2500:])
        code, log = self.ssh('cat /reinstall.log', timeout=120)
        (self.work / 'installer.log').write_text(log, encoding='utf-8')
        # Validate filesystem and UUID layout before allowing installed OS to boot.
        self.ssh('''set -e
test "$(blockdev --getsize64 /dev/vda2)" = 2147483648
test "$(blockdev --getsize64 /dev/vda3)" = 17179869184
cat /os/etc/fstab
chroot /os grub-script-check /boot/grub/grub.cfg
echo ci-persistence-marker >/os/data/.ci-marker
sync
''')
        self.ssh('nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 </dev/null &')
        time.sleep(15)

    def verify(self, phase):
        output = self.wait('test ! -f /etc/alpine-release && test -f /data/.ci-marker && echo INSTALLED_READY',
                           'INSTALLED_READY', 900)
        mode_check = 'test -d /sys/firmware/efi' if self.firmware == 'uefi' else 'test ! -d /sys/firmware/efi'
        script = f'''set -e
{mode_check}
test "$(findmnt -n -o SOURCE /)" = /dev/vda3
test "$(findmnt -n -o SOURCE /boot)" = /dev/vda2
test "$(findmnt -n -o SOURCE /data)" = /dev/vda4
test "$(blockdev --getsize64 /dev/vda3)" = 17179869184
grep -qx ci-persistence-marker /data/.ci-marker
test "$(findmnt -n -o FSTYPE /data)" = ext4
systemctl is-active ssh
lsblk -b -o NAME,SIZE,FSTYPE,MOUNTPOINTS
cat /etc/fstab
uname -r
curl -4 -fsI --max-time 30 https://archive.ubuntu.com/ubuntu/ >/dev/null
echo CI_BOOT_VERIFIED
'''
        if self.firmware == 'uefi':
            script += '''test "$(findmnt -n -o SOURCE /boot/efi)" = /dev/vda1
test "$(blockdev --getsize64 /dev/vda1)" = 536870912
boot_uuid=$(lsblk -dnro UUID /dev/vda2)
grep -q -- "--set=root $boot_uuid" /boot/efi/EFI/ubuntu/grub.cfg
efibootmgr
'''
        self.ssh(script, timeout=90)
        expected_data = (32767 - (18945 if self.firmware == 'uefi' else 18434)) * 1048576
        self.ssh(f'test "$(blockdev --getsize64 /dev/vda4)" = {expected_data}')
        _, boot_id = self.ssh('cat /proc/sys/kernel/random/boot_id')
        boot_id = boot_id.strip()
        if boot_id == self.last_boot_id:
            raise RuntimeError('Reboot did not produce a new kernel boot ID')
        self.last_boot_id = boot_id
        self.note(f'{self.firmware}: {phase} verified')

    def maintenance(self):
        # Exercise kernel hooks using the installed version (not a claimed upgrade).
        self.ssh('nohup sh -c \'set -e; DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y "linux-image-$(uname -r)"; grub-script-check /boot/grub/grub.cfg; echo CI_KERNEL_DONE\' >/root/ci-kernel.log 2>&1 </dev/null &')
        self.wait('tail -20 /root/ci-kernel.log', 'CI_KERNEL_DONE', 1200)
        self.ssh('nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 </dev/null &')
        time.sleep(15)
        self.verify('boot after kernel maintenance')
        self.ssh('nohup sh -c "sleep 2; poweroff" >/dev/null 2>&1 </dev/null &')
        self.process.wait(timeout=180)
        self.qemu_log.close()
        # A new process, same disk and persistent NVRAM, without bootstrap seed.
        self.start(seed=False)
        self.verify('cold boot')

    def close(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if hasattr(self, 'qemu_log'):
            self.qemu_log.close()
        self.log.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--firmware', choices=['bios', 'uefi'], required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    vm = VM(args.firmware, args.source, args.work)
    result = {'firmware': args.firmware, 'passed': False}
    try:
        vm.setup()
        vm.start(seed=True)
        vm.prepare_install()
        vm.verify('first installed boot')
        vm.maintenance()
        result['passed'] = True
        vm.note('FULL_INSTALL_BOOT_TEST_PASSED')
    except Exception as exc:
        result['error'] = str(exc)[-4000:]
        vm.note('FULL_INSTALL_BOOT_TEST_FAILED: ' + str(exc)[-4000:])
        raise
    finally:
        (vm.work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        vm.close()


if __name__ == '__main__':
    main()
