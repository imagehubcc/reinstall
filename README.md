# reinstall 自定义分区增强版

基于 [bin456789/reinstall](https://github.com/bin456789/reinstall)，增加 Ubuntu 24.04 x86_64 自定义 GPT 分区功能，保留官方提交历史。

[![Custom partitions](https://github.com/imagehubcc/reinstall/actions/workflows/custom-partitions.yml/badge.svg)](https://github.com/imagehubcc/reinstall/actions/workflows/custom-partitions.yml)

> [!CAUTION]
> 重装会清空目标磁盘的全部数据，包括已有的 `/data` 分区。操作前请备份，并确保可通过控制台或 IPMI 恢复访问。

## 功能

- 自定义根分区、可选独立 `/boot` 和数据分区大小。
- 数据分区支持固定大小或 `rest` 使用剩余空间，默认挂载到 `/data`。
- 自动识别 BIOS/UEFI：UEFI 默认创建 512MiB EFI 分区；BIOS 创建 1MiB BIOS-GRUB 保留分区。
- 清盘前检查参数与容量，自动配置 UUID 挂载和引导。

自定义分区目前仅支持 **Linux → Ubuntu 24.04 x86_64 云镜像安装**。使用普通 GPT 分区，root/boot/data 为 ext4，EFI 为 FAT32。
不支持新增参数的场景：其他发行版或版本、ARM、Windows 入口、ISO 安装、LVM、软件 RAID、阵列创建或调整、加密及保留已有分区。
**不传自定义分区参数时，沿用原作者脚本的默认安装逻辑和功能**；其他系统及用法参阅 [上游文档](https://github.com/bin456789/reinstall#readme)。

## 使用

获取完整代码，勿仅下载入口脚本：

```sh
git clone --branch main https://github.com/imagehubcc/reinstall.git
cd reinstall
```

可选的离线布局预览，不会读取或修改磁盘：

```sh
sh partition-plan.sh --disk-size 256GiB --boot-mode bios \
  --root-size 64GiB --boot-size 2GiB --data-size rest
```

准备重装。实际引导模式和磁盘容量自动识别，无需指定 EFI 大小：

```sh
sudo bash reinstall.sh ubuntu 24.04 \
  --username root \
  --password 'YOUR_ROOT_PASSWORD' \
  --root-size 64GiB \
  --boot-size 2GiB \
  --data-size rest \
  --data-mount /data \
  --hold 2
```

`--username root` 指定 root 账号，`--password 'YOUR_ROOT_PASSWORD'` 设置该账号密码，请将占位符替换为自己的密码。省略这两个参数时按提示设置。命令行密码会留在 shell 历史中，也可省略 `--password`，改用交互输入。
SSH 默认端口为 22；如需修改，可添加 `--ssh-port 2222`（示例值），并确认网络允许访问。
多磁盘机器应先用 `lsblk` 确认目标，再通过 `--target-disk` 指定。

准备完成后执行 `sudo reboot`，开始重装。`--hold 2` 会在安装结束后暂停，新系统挂载于 `/os`：

```sh
lsblk -b -o NAME,SIZE,FSTYPE,MOUNTPOINTS
cat /os/etc/fstab
```

确认后执行 `reboot` 进入新系统。省略 `--hold 2` 时，安装结束后自动重启。

## 分区参数

| 参数 | 说明 |
| --- | --- |
| `--root-size SIZE` | 自定义模式必填，至少 8GiB |
| `--boot-size SIZE` | 可选独立 `/boot`，至少 512MiB；省略或设为 `0` 则不单独分区 |
| `--data-size SIZE` 或 `--data-size rest` | 可选数据分区，至少 1GiB；`rest` 使用剩余可用空间 |
| `--data-mount /PATH` | 数据分区挂载点，默认 `/data` |
| `--efi-size SIZE` | 可选 UEFI 大小覆盖，默认 512MiB，至少 100MiB；通常无需指定 |

SIZE 支持正整数 `MiB/GiB/TiB`、十进制 `MB/GB/TB`，以及二进制别名 `M/G/T`。十进制大小向上取整到 MiB。
固定大小分配后多余空间保持未分配；`df` 显示的文件系统容量会小于分区大小。
BIOS 下显式传入 `--efi-size` 会在准备阶段报错退出，不会继续清盘；该参数不会改变固件模式。

## 自动同步上游

每天北京时间 09:23 检测官方更新，合并候选版本后运行现有检查及 BIOS/UEFI 完整重装与启动测试，
全部通过才更新 `main`。冲突或失败保持 `main` 不变，通过 GitHub Issue 通知。
测试使用 GitHub 托管 runner，无需另备服务器。支持在 Actions 手动触发。

## 验证与维护

已完成 BIOS VPS、BIOS 独立服务器和嵌套 KVM/OVMF UEFI 的重装、内核维护及启动验证，UEFI 另通过持久 NVRAM 冷启动验证。

- [分区规则与上游更新流程](CUSTOM-PARTITIONS.md)
- [验证范围](VPS-VALIDATION.md)
- [GitHub Actions](https://github.com/imagehubcc/reinstall/actions/workflows/custom-partitions.yml)

主要改动位于 `reinstall.sh`、`trans.sh` 和独立的 `partition-layout.sh`。保留上游 GPL-3.0 许可及作者信息。
