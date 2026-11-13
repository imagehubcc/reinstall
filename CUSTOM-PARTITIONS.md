# 分区规则与维护

基本用法见 [README](README.md)，验证范围见 [VPS-VALIDATION.md](VPS-VALIDATION.md)。

## 分区规则

- 自定义模式要求固定大小的根分区；`/boot` 和数据分区可选。
- 自动判断 BIOS/UEFI。UEFI 默认 EFI 大小为 512MiB；BIOS 不创建 EFI 分区。
- `--efi-size` 只覆盖 UEFI 默认值，BIOS 下指定时会提前报错。
- 数据分区为固定大小或 `rest`；未分配的空间不会自动并入根分区。
- 数据挂载点支持 `/data`、`/srv/storage`、`/home` 等普通绝对路径。
  拒绝空格、点路径、符号链接及 `/boot`、`/etc`、`/usr`、`/var` 等关键系统目录。
- 分区大小按 MiB 对齐，预留引导及 GPT 元数据空间。文件系统元数据与保留块会影响可用容量。

安装时先建立引导分区、可选 boot、root 和临时 installer。系统复制完成后删除 installer，
再创建 data，因此 `rest` 可回收临时安装空间，无需缩小根分区。
root/boot 使用目标系统的格式化工具；fstab 使用实际 UUID，EFI 跳转按 boot 文件系统生成。

`--hold 2` 可暂停在安装完成后的 Alpine 环境。自定义模式禁用 `/trans.sh update`，
避免混入其他版本的安装逻辑；需要更新时应重新获取完整仓库。

## 持续合并上游

`origin` 对应本 fork，`upstream` 对应官方仓库。首次添加官方远端：

```sh
git remote add upstream https://github.com/bin456789/reinstall.git
```

在干净工作区创建集成分支：

```sh
git fetch upstream
git switch -c integrate/upstream-YYYYMMDD
python3 tools/check-upstream.py upstream/main
git merge upstream/main
```

适配冲突后，将本次官方完整提交号写入 `UPSTREAM_COMMIT`，运行测试并完成安装回归，再合入 `main`。
不能只更新版本记录而不合并源码。重点检查分区、文件复制、GRUB、启动参数及 initrd 打包逻辑；
无 Git 冲突不代表安装兼容，不在重装期间动态合并上游。

## 测试与打包

```sh
python3 tests/test_partitions.py
PARTITION_SHELL='busybox ash' python3 tests/test_partitions.py
shellcheck -s bash partition-layout.sh partition-plan.sh tests/loop-layout.sh
bash -n reinstall.sh
bash -n trans.sh
python3 tools/build-bundle.py
```

离线测试使用命令替身拦截磁盘写入。GitHub Actions 另使用临时 loop 镜像测试分区、格式化和挂载，
不连接用户服务器。完整安装与启动仍需在可清空的测试环境中验证。

发布包位于 `dist/`，包含提交信息及 SHA-256 清单；未提交工作区的包标记为开发版。
使用同一版本的入口、安装脚本、分区模块和 `UPSTREAM_COMMIT`，勿只下载入口脚本。
临时目录和打包产物不提交到仓库。
