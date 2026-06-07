#!/bin/bash
set -e

PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_DIR=/root/dlcv

echo "[INFO] 安装 DLCV 智能相机环境到 $ENV_DIR"

# 1. 安装系统依赖
if command -v apt-get >/dev/null 2>&1; then
    echo "[INFO] 安装系统依赖..."
    apt-get update
    apt-get install -y python3-gi \
        gir1.2-gstreamer-1.0 gstreamer1.0-tools \
        gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
        chromium-x11
fi

# 2. 解压环境包（优先 tar.gz，保留 Unix 软链接）
if [ -f "$PKG_DIR/dlcv_env.tar.gz" ]; then
    echo "[INFO] 解压 tar.gz 环境包..."
    tar -xzf "$PKG_DIR/dlcv_env.tar.gz" -C /root
elif [ -f "$PKG_DIR/dlcv_env.7z" ]; then
    echo "[WARN] 使用 7z 环境包，Unix 软链接可能丢失"
    mkdir -p "$ENV_DIR"
    7z x -y -o/root "$PKG_DIR/dlcv_env.7z"
else
    echo "[ERROR] 未找到 $PKG_DIR/dlcv_env.tar.gz 或 $PKG_DIR/dlcv_env.7z"
    exit 1
fi

# 3. 部署系统级依赖库
echo "[INFO] 部署 librknnrt.so 到 /usr/lib"
cp -f "$ENV_DIR/bin/librknnrt.so" /usr/lib/librknnrt.so
chmod 644 /usr/lib/librknnrt.so
ldconfig

# 4. 设置可执行权限
chmod +x "$ENV_DIR/bin/pressure_test" "$ENV_DIR/bin/rtop" "$ENV_DIR/bin/debug" "$ENV_DIR/bin/dlcv_infer_cpp_qt_demo" "$ENV_DIR/bin/ai_model_accelerator.bin" 2>/dev/null || true

# 5. 修复 python 软链接（7z 解压会忽略危险链接）
if [ ! -e "$ENV_DIR/bin/python" ]; then
    ln -sf "$ENV_DIR/.python-runtime/bin/python3.11" "$ENV_DIR/bin/python"
    ln -sf python "$ENV_DIR/bin/python3"
    ln -sf python "$ENV_DIR/bin/python3.11"
fi

# 6. 修复 ai_model_accelerator.bin 软链接
ACCEL_BIN="$ENV_DIR/bin/ai_model_accelerator.bin"
if [ -L "$ACCEL_BIN" ]; then
    TARGET=$(readlink "$ACCEL_BIN")
    if echo "$TARGET" | grep -q "/root/root/dlcv"; then
        NEW_TARGET=$(echo "$TARGET" | sed 's|/root/root/dlcv|/root/dlcv|')
        ln -snf "$NEW_TARGET" "$ACCEL_BIN"
        echo "[INFO] 修复 ai_model_accelerator.bin 软链接"
    fi
fi

# 8. 配置 activate 脚本中的 LD_LIBRARY_PATH（供 debug / Qt demo 找到 libdlcv_infer_cpp_dll.so 等）
ACTIVATE_FILE="$ENV_DIR/bin/activate"
if [ -f "$ACTIVATE_FILE" ] && ! grep -qF "DLCV_LDPATH" "$ACTIVATE_FILE" 2>/dev/null; then
    cat >> "$ACTIVATE_FILE" << 'EOF'

# DLCV 本地库路径
DLCV_LDPATH="/root/dlcv/bin/lib:/root/dlcv/lib:/root/dlcv/bin"
if [ -z "${LD_LIBRARY_PATH-}" ] ; then
    LD_LIBRARY_PATH="$DLCV_LDPATH"
else
    LD_LIBRARY_PATH="$DLCV_LDPATH:$LD_LIBRARY_PATH"
fi
export LD_LIBRARY_PATH
EOF
    echo "[INFO] 已配置 activate 中的 LD_LIBRARY_PATH"
fi

# 9. 安装 Sentinel 加密狗驱动（若安装包存在于环境目录中）
DONGLE_DEB=$(find "$ENV_DIR/bin" -maxdepth 1 -name 'aksusbd_*_arm64.deb' | head -n 1)
if [ -n "$DONGLE_DEB" ] && ! dpkg -l aksusbd 2>/dev/null | grep -q "^ii"; then
    echo "[INFO] 安装 Sentinel 加密狗驱动: $(basename "$DONGLE_DEB")"
    dpkg -i "$DONGLE_DEB" || apt-get install -f -y
    systemctl enable hasplmd.service 2>/dev/null || true
    systemctl start hasplmd.service 2>/dev/null || true
    echo "[INFO] 加密狗驱动安装完成，服务已启动"
fi

# 10. 永久激活环境（写入 shell 配置文件）
ACTIVATE_LINE="source $ENV_DIR/bin/activate"
for RC in ~/.bashrc ~/.zshrc; do
    if [ -f "$RC" ]; then
        if ! grep -qF "$ACTIVATE_LINE" "$RC" 2>/dev/null; then
            echo "$ACTIVATE_LINE" >> "$RC"
            echo "[INFO] 已添加环境激活到 $RC"
        fi
    fi
done

# 11. 立即激活当前 shell
source "$ENV_DIR/bin/activate"

echo "[INFO] 安装完成，环境已激活"
echo "[INFO] 当前 Python: $(which python)"

# 12. 检查加密狗
if lsusb | grep -q "Aladdin\|Sentinel"; then
    echo "[INFO] 检测到 Sentinel 加密狗"
else
    echo "[WARN] 未检测到 Sentinel 加密狗，请插入 USB 加密狗后执行: systemctl restart hasplmd.service"
fi
