#!/bin/bash -e
set -o pipefail

# 把 dlcv_env.tar.gz 解压到 dlcv 独立分区的源目录 dlcv_part_src/。
# 该目录被 device 侧 RK_EXTRA_PARTITION_3_SRC 引用，由 mk-extra-parts.sh 打成 dlcv.img。
#
# 用法：
#   - 完整固件构建时由 mk-bookworm-rootfs.sh 调用；
#   - 仅更新环境时可单独执行本脚本，然后 `./build.sh firmware` 重打 dlcv.img 与 update.img，
#     无需重建 rootfs。

HERE="$(cd "$(dirname "$0")" && pwd)"
DLCV_PART_SRC="$HERE/dlcv_part_src"

# 查找候选环境压缩包
CANDIDATES=(
    "${DLCV_ENV_TAR:-}"
    "$HERE/dlcv_env.tar.gz"
    "/share/4-智能相机/0-环境安装/dlcv_env.tar.gz"
)

FOUND_TAR=""
for c in "${CANDIDATES[@]}"; do
    if [ -n "$c" ] && [ -f "$c" ]; then
        FOUND_TAR="$c"
        break
    fi
done

sudo rm -rf "$DLCV_PART_SRC"
mkdir -p "$DLCV_PART_SRC"

if [ -n "$FOUND_TAR" ]; then
    echo -e "\033[47;36m ---------- Extract dlcv env: $FOUND_TAR -> $DLCV_PART_SRC ---------- \033[0m"
    sudo tar -xzf "$FOUND_TAR" -C "$DLCV_PART_SRC" --strip-components=1 dlcv
else
    echo -e "\033[33m [WARNING] dlcv_env.tar.gz not found. Initializing basic clean partition structure. \033[0m"
    sudo mkdir -p "$DLCV_PART_SRC/bin" "$DLCV_PART_SRC/lib"
    # Extract librknnrt.so from rknpu2.tar if available to provide system runtime
    if [ -f "$HERE/packages/arm64/rknpu2/rknpu2.tar" ]; then
        tar -xf "$HERE/packages/arm64/rknpu2/rknpu2.tar" ./usr/lib/librknnrt.so -O | sudo tee "$DLCV_PART_SRC/bin/librknnrt.so" > /dev/null 2>&1 || true
    fi
    echo "OKayPi partition placeholder" | sudo tee "$DLCV_PART_SRC/README.txt" > /dev/null
fi

if [ ! -d "$DLCV_PART_SRC/bin" ]; then
    echo -e "\033[41;36m ERROR: dlcv env setup failed, $DLCV_PART_SRC/bin missing \033[0m" >&2
    exit 1
fi

echo -e "\033[47;36m dlcv_part_src ready: $(sudo du -sh "$DLCV_PART_SRC" | cut -f1) \033[0m"
