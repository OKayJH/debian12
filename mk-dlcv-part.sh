#!/bin/bash -e
set -o pipefail

# 把 dlcv_env_2026.09.03_115549_ar0521.tar.gz 解压到 dlcv 独立分区的源目录 dlcv_part_src/。
# 该目录被 device 侧 RK_EXTRA_PARTITION_3_SRC 引用，由 mk-extra-parts.sh 打成 dlcv.img。
#
# 用法：
#   - 完整固件构建时由 mk-bookworm-rootfs.sh 调用；
#   - 仅更新环境时可单独执行本脚本，然后 `./build.sh firmware` 重打 dlcv.img 与 update.img，
#     无需重建 rootfs。

HERE="$(cd "$(dirname "$0")" && pwd)"
DLCV_ENV_TAR="${DLCV_ENV_TAR:-/share/4-智能相机/0-环境安装/dlcv_env_2026.09.03_115549_ar0521.tar.gz}"
DLCV_PART_SRC="$HERE/dlcv_part_src"

if [ ! -f "$DLCV_ENV_TAR" ]; then
    echo -e "\033[41;36m ERROR: $DLCV_ENV_TAR not found \033[0m" >&2
    exit 1
fi

echo -e "\033[47;36m ---------- Extract dlcv env -> $DLCV_PART_SRC ---------- \033[0m"
sudo rm -rf "$DLCV_PART_SRC"
mkdir -p "$DLCV_PART_SRC"

# tar 顶层为 dlcv/，--strip-components=1 后分区根目录即环境内容（bin/ lib/ ...）。
sudo tar -xzf "$DLCV_ENV_TAR" -C "$DLCV_PART_SRC" --strip-components=1 dlcv

if [ ! -d "$DLCV_PART_SRC/bin" ]; then
    echo -e "\033[41;36m ERROR: dlcv env extraction failed, $DLCV_PART_SRC/bin missing \033[0m" >&2
    exit 1
fi

echo -e "\033[47;36m dlcv_part_src ready: $(sudo du -sh "$DLCV_PART_SRC" | cut -f1) \033[0m"
