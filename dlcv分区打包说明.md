# dlcv 独立分区打包说明

> RK3576 智能相机固件中，Python 环境 `/root/dlcv` 从 rootfs 中剥离为独立 `dlcv` ext4 分区。
> 本文档记录该机制的组成、构建与更新流程、烧录与验证方法。仅记录事实。

## 一、分区结构

`/root/dlcv` 不再烤进 rootfs，改为独立分区，运行期挂载到 `/root/dlcv`。

分区表（`device/rockchip/.chips/rk3576/parameter.txt`）顺序：

```
uboot → misc → boot → recovery → backup → oem → userdata → dlcv → rootfs(grow)
```

- `dlcv`：`0x00600000@0x002b8000`，3 GiB，设备节点 `mmcblk0p8`，PARTLABEL=`dlcv`。
- `rootfs`：起始 `0x008b8000`，grow，末位，设备节点 `mmcblk0p9`。

## 二、组成与各文件职责

| 文件 | 仓库 | 职责 |
|------|------|------|
| `parameter.txt` | device | 倒数第二位插入 `dlcv` 分区（3 GiB），`rootfs` 后移并保持 grow 末位 |
| `dlcvcam_rk3576_debian12_gnome_defconfig` | device | `RK_EXTRA_PARTITION_NUM=3` + 分区 3 `dlcv`：`EXT4` / `MOUNTPOINT=/root/dlcv` / `SIZE=max`（按 parameter.txt 中 3 GiB 打镜像）/ `SRC` 指向暂存目录 |
| `mk-dlcv-part.sh` | debian12 | 把 `dlcv_env.tar.gz` 解压到 `dlcv_part_src/`（即 `RK_EXTRA_PARTITION_3_SRC`），供 `mk-extra-parts.sh` 打成 `dlcv.img` |
| `mk-bookworm-rootfs.sh` | debian12 | 调用 `mk-dlcv-part.sh`；从 `dlcv_part_src/` 取系统侧文件进 rootfs（`librknnrt.so` → `/usr/lib`，加密狗驱动 deb → `/tmp`）；`/root/dlcv` 仅保留为空挂载点，不再烤入环境 |
| `overlay/etc/fstab` | debian12 | 增加 `PARTLABEL=dlcv  /root/dlcv  ext4  defaults  0 2` |

> `dlcv_part_src/` 是构建期暂存目录，已在 `.gitignore` 忽略，不进 git。
> `SRC` 在 defconfig 中为绝对路径，指向 SDK 内 `debian12/dlcv_part_src`。

## 三、构建 / 更新流程

### A. 完整固件（首次构建，或 rootfs 内容/系统依赖有变更）

```bash
cd <SDK 根目录>
make dlcvcam_rk3576_debian12_gnome_defconfig
rm -f debian12/linaro-rk3576-gnome-rootfs.img   # 改了 mk-bookworm 必须删旧缓存
./build.sh all
```

`build.sh all` 会：重建 base rootfs（含 chroot apt）→ `mk-dlcv-part.sh` 解压环境到 `dlcv_part_src/` → `mk-extra-parts.sh` 打 `dlcv.img` → 打 `update.img`（含 `oem/userdata/dlcv/rootfs`）。

### B. 仅更新环境（不重建 rootfs，代价小）

环境包 `dlcv_env.tar.gz` 更新、rootfs 无变化时：

```bash
cd <SDK 根目录>/debian12
./mk-dlcv-part.sh            # 重新解压环境到 dlcv_part_src/
cd ..
./build.sh firmware         # 重打 dlcv.img + 重新打包 update.img，rootfs 复用缓存
```

`./build.sh firmware` 不触发 base 解压与 chroot apt，仅 rsync 环境 + mkfs `dlcv.img` + 重打 `update.img`。

## 四、烧录

- **完整 `update.img`**：写分区表 + 全部分区。改了分区表后，存量设备需用此方式一次性迁移。
- **仅烧 `dlcv` 分区**：RKDevTool 分区烧写时同时勾选 `parameter.txt` 与 `dlcv.img`（写 `dlcv` 分区），rootfs 不动。

## 五、验证（loop-mount）

```bash
sudo mount -o loop,ro output/firmware/dlcv.img /mnt      # 顶层应为 bin/ lib/ .python-runtime/ 等环境内容
sudo mount -o loop,ro output/firmware/rootfs.img /mnt    # /root/dlcv 应为空目录；/usr/lib/librknnrt.so 应存在；/etc/fstab 应含 dlcv 行
```

## 六、已确认事实（2026-07-01 构建）

| 项 | 值 |
|----|----|
| `dlcv.img` | 3.0 GiB（环境占 2.3 GiB，余 471 MiB） |
| `rootfs.img` | 6.4 GiB（不含环境） |
| `update.img` | 9.5 GiB，`package-file` 含 `oem / userdata / dlcv / rootfs` |
| `dlcv.img` 内 `gi` | 环境内真实包（非软链），无需构建期 `gi` 软链修复 |
| `dlcv.img` 内属主 | 打包后为 `root:root`（venv 只读运行不受影响） |
