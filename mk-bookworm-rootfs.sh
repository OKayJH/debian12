#!/bin/bash -e
set -o pipefail

# Directory contains the target rootfs
TARGET_ROOTFS_DIR="binary"

if [ ! $SOC ]; then
    echo "---------------------------------------------------------"
    echo "please enter soc number:"
    echo "请输入要构建CPU的序号:"
    echo "[0] Exit Menu"
    echo "[1] rk3128"
    echo "[2] rk3528"
    echo "[3] rk3562"
    echo "[4] rk3566/rk3568"
    echo "[5] rk3576"
    echo "[6] rk3588/rk3588s"
    echo "---------------------------------------------------------"
    read input

    case $input in
        0)  exit ;;
        1)  SOC=rk3128 ;;
        2)  SOC=rk3528 ;;
        3)  SOC=rk3562 ;;
        4)  SOC=rk356x ;;
        5)  SOC=rk3576 ;;
        6)  SOC=rk3588 ;;
        *)  echo 'input soc number error, exit !'
            exit;;
    esac
    echo -e "\033[47;36m set SOC=$SOC...... \033[0m"
fi

if [ ! $TARGET ]; then
    echo "---------------------------------------------------------"
    echo "please enter TARGET version number:"
    echo "请输入要构建的根文件系统版本:"
    echo "[0] Exit Menu"
    echo "[1] xfce"
    echo "[2] lxde"
    echo "[3] gnome"
    echo "[4] lite"
    echo "---------------------------------------------------------"
    read input

    case $input in
        0)  exit ;;
        1)  TARGET=xfce ;;
        2)  TARGET=lxde ;;
        3)  TARGET=gnome ;;
        4)  TARGET=lite ;;
        *)  echo -e "\033[47;36m input TARGET version number error, exit ! \033[0m"
            exit;;
    esac
    echo -e "\033[47;36m set TARGET=$TARGET...... \033[0m"
fi

install_packages() {
    case $SOC in
        rk3399|rk3399pro)
        MALI=midgard-t86x-r18p0
        MALI_PKG=libmali-*$MALI*-x11*
        ISP=rkisp
        ;;
        rk3328|rk3528)
        MALI=utgard-450
        MALI_PKG=libmali-*$MALI*-x11*
        ISP=rkisp
        MIRROR=carp-rk352x
        ;;
        rk3128|rk3036)
        MALI=utgard-400
        MALI_PKG=libmali-*$MALI*-x11*
        ISP=rkisp
        ;;
        rk3562)
        MALI=bifrost-g52-g24p0
        MALI_PKG=libmali-*$MALI*-x11-wayland-gbm*
        ISP=rkaiq_rk3562
        MIRROR=carp-rk356x
        ;;
        rk356x|rk3566|rk3568)
        MALI=bifrost-g52-g24p0
        MALI_PKG=libmali-*$MALI*-x11-wayland-gbm*
        ISP=rkaiq_rk3568
        MIRROR=carp-rk356x
        ;;
        rk3576)
        MALI=bifrost-g52-g13p0
        MALI_PKG=libmali-*$MALI*-x11-wayland-gbm*
        ISP=rkaiq_rk3576
        ;;
        rk3588|rk3588s)
        MALI=valhall-g610-g24p0
        MALI_PKG=libmali-*$MALI*-x11-wayland-gbm*
        ISP=rkaiq_rk3588
        MIRROR=carp-rk3588
        ;;
    esac
}

case "${ARCH:-$1}" in
    arm|arm32|armhf)
        ARCH=armhf
        ;;
    *)
        ARCH=arm64
        ;;
esac

echo -e "\033[47;36m Building for $ARCH \033[0m"

if [ ! $VERSION ]; then
    VERSION="release"
fi

echo -e "\033[47;36m Building for $VERSION \033[0m"

if [ ! -e linaro-bookworm-$TARGET-$ARCH-alip-*.tar.gz ]; then
    echo "\033[41;36m Run mk-base-debian.sh first \033[0m"
    exit -1
fi

echo -e "\033[47;36m Extract image \033[0m"
sudo rm -rf $TARGET_ROOTFS_DIR
sudo tar -xpf linaro-bookworm-$TARGET-$ARCH-alip-*.tar.gz

# packages folder
sudo mkdir -p $TARGET_ROOTFS_DIR/packages
sudo cp -rpf packages/$ARCH/* $TARGET_ROOTFS_DIR/packages

#GPU/CAMERA packages folder
install_packages
sudo mkdir -p $TARGET_ROOTFS_DIR/packages/install_packages
sudo cp -rpfv packages/$ARCH/libmali/$MALI_PKG.deb $TARGET_ROOTFS_DIR/packages/install_packages
sudo cp -rpfv packages/$ARCH/${ISP:0:5}/camera_engine_$ISP*.deb $TARGET_ROOTFS_DIR/packages/install_packages

#linux kernel deb
if [ -e ../linux-headers* ]; then
    Image_Deb=$(basename ../linux-headers*)
    sudo mkdir -p $TARGET_ROOTFS_DIR/boot/kerneldeb
    sudo touch $TARGET_ROOTFS_DIR/boot/build-host
    sudo cp -vrpf ../${Image_Deb} $TARGET_ROOTFS_DIR/boot/kerneldeb
    sudo cp -vrpf ../${Image_Deb/headers/image} $TARGET_ROOTFS_DIR/boot/kerneldeb
fi

# overlay folder
sudo cp -rpf overlay/* $TARGET_ROOTFS_DIR/

# Copy SSH authorized_keys if exists
if [ -f authorized_keys ]; then
    sudo cp -pf authorized_keys $TARGET_ROOTFS_DIR/
fi

# overlay-firmware folder
sudo cp -rpf overlay-firmware/* $TARGET_ROOTFS_DIR/

# overlay-debug folder
# adb, video, camera  test file
if [ "$VERSION" == "debug" ]; then
    sudo cp -rpf overlay-debug/* $TARGET_ROOTFS_DIR/
fi

#---------------DLCV Environment Pre-extract--------------
DLCV_ENV_TAR="/share/4-智能相机/0-环境安装/dlcv_env.tar.gz"
DLCV_ENV_7Z="/share/4-智能相机/0-环境安装/dlcv_env.7z"

if [ -f "$DLCV_ENV_TAR" ]; then
    echo -e "\033[47;36m ---------- Pre-extracting DLCV environment (tar.gz) -------- \033[0m"
    sudo mkdir -p $TARGET_ROOTFS_DIR/root/dlcv
    sudo rm -rf $TARGET_ROOTFS_DIR/root/dlcv_extract_tmp
    sudo mkdir -p $TARGET_ROOTFS_DIR/root/dlcv_extract_tmp
    sudo tar -xzf "$DLCV_ENV_TAR" -C "$TARGET_ROOTFS_DIR/root/dlcv_extract_tmp" 2>/dev/null || true
    if [ -d "$TARGET_ROOTFS_DIR/root/dlcv_extract_tmp/root/dlcv" ]; then
        sudo cp -a $TARGET_ROOTFS_DIR/root/dlcv_extract_tmp/root/dlcv/. $TARGET_ROOTFS_DIR/root/dlcv/
        sudo rm -rf $TARGET_ROOTFS_DIR/root/dlcv_extract_tmp
    elif [ -d "$TARGET_ROOTFS_DIR/root/dlcv_extract_tmp/dlcv" ]; then
        sudo cp -a $TARGET_ROOTFS_DIR/root/dlcv_extract_tmp/dlcv/. $TARGET_ROOTFS_DIR/root/dlcv/
        sudo rm -rf $TARGET_ROOTFS_DIR/root/dlcv_extract_tmp
    fi
elif [ -f "$DLCV_ENV_7Z" ] && command -v 7zz >/dev/null 2>&1; then
    echo -e "\033[47;36m ---------- Pre-extracting DLCV environment (7z) -------- \033[0m"
    sudo mkdir -p $TARGET_ROOTFS_DIR/root/dlcv
    sudo rm -rf $TARGET_ROOTFS_DIR/root/dlcv_extract_tmp
    set +e
    sudo 7zz x -y "$DLCV_ENV_7Z" -o"$TARGET_ROOTFS_DIR/root/dlcv_extract_tmp" >/dev/null 2>&1
    EXTRACT_EXIT=$?
    set -e
    if [ $EXTRACT_EXIT -ge 2 ]; then
        echo -e "\033[43;36m WARNING: 7zz exited with code $EXTRACT_EXIT, continuing anyway \033[0m"
    fi
    if [ -d "$TARGET_ROOTFS_DIR/root/dlcv_extract_tmp/dlcv" ]; then
        sudo cp -a $TARGET_ROOTFS_DIR/root/dlcv_extract_tmp/dlcv/. $TARGET_ROOTFS_DIR/root/dlcv/
        sudo rm -rf $TARGET_ROOTFS_DIR/root/dlcv_extract_tmp
    fi
fi

if [ -d "$TARGET_ROOTFS_DIR/root/dlcv/bin" ]; then
    # Fix python symlinks (7z may create empty files for dangerous links)
    PYTHON_BIN="/root/dlcv/.python-runtime/bin/python3.11"
    if [ -e "$TARGET_ROOTFS_DIR$PYTHON_BIN" ]; then
        sudo ln -sf "$PYTHON_BIN" "$TARGET_ROOTFS_DIR/root/dlcv/bin/python"
        sudo ln -sf python "$TARGET_ROOTFS_DIR/root/dlcv/bin/python3"
        sudo ln -sf python "$TARGET_ROOTFS_DIR/root/dlcv/bin/python3.11"
    fi

    # Fix absolute path symlinks broken by 7z extraction
    sudo bash -c '
        find "$0/root/dlcv" -type l | while read -r LINK; do
            T=$(readlink "$LINK")
            if echo "$T" | grep -q "/root/root/dlcv"; then
                NT=$(echo "$T" | sed "s|/root/root/dlcv|/root/dlcv|")
                ln -snf "$NT" "$LINK"
            elif echo "$T" | grep -q "^/root/usr/lib"; then
                NT=$(echo "$T" | sed "s|^/root/usr/lib|/usr/lib|")
                [ -e "$0$NT" ] && ln -snf "$NT" "$LINK"
            fi
        done
    ' "$TARGET_ROOTFS_DIR"

    # Fix lib64 duplicate directory (7z may turn symlink into actual directory)
    if [ -d "$TARGET_ROOTFS_DIR/root/dlcv/lib64" ] && [ ! -L "$TARGET_ROOTFS_DIR/root/dlcv/lib64" ]; then
        sudo rm -rf "$TARGET_ROOTFS_DIR/root/dlcv/lib64"
        sudo ln -s lib "$TARGET_ROOTFS_DIR/root/dlcv/lib64"
    fi

    # Fix known DLCV symlinks that 7z turns into copied files
    # ai_model_accelerator
    if [ -f "$TARGET_ROOTFS_DIR/root/dlcv/lib/python3.11/site-packages/dlcvpro_deploy/ai_model_accelerator_v.bin" ]; then
        sudo rm -f "$TARGET_ROOTFS_DIR/root/dlcv/bin/ai_model_accelerator_v.bin"
        sudo ln -sf /root/dlcv/lib/python3.11/site-packages/dlcvpro_deploy/ai_model_accelerator_v.bin "$TARGET_ROOTFS_DIR/root/dlcv/bin/ai_model_accelerator_v.bin"
    fi
    if [ -f "$TARGET_ROOTFS_DIR/root/dlcv/lib/python3.11/site-packages/dlcvpro_deploy/ai_model_accelerator_s.bin" ]; then
        sudo rm -f "$TARGET_ROOTFS_DIR/root/dlcv/bin/ai_model_accelerator_s.bin"
        sudo ln -sf /root/dlcv/lib/python3.11/site-packages/dlcvpro_deploy/ai_model_accelerator_s.bin "$TARGET_ROOTFS_DIR/root/dlcv/bin/ai_model_accelerator_s.bin"
    fi
    # gi (system package symlink)
    if [ -d "$TARGET_ROOTFS_DIR/root/dlcv/lib/python3.11/site-packages/gi" ] && [ ! -L "$TARGET_ROOTFS_DIR/root/dlcv/lib/python3.11/site-packages/gi" ]; then
        sudo rm -rf "$TARGET_ROOTFS_DIR/root/dlcv/lib/python3.11/site-packages/gi"
        sudo ln -sf /usr/lib/python3/dist-packages/gi "$TARGET_ROOTFS_DIR/root/dlcv/lib/python3.11/site-packages/gi"
    fi

    # Deploy librknnrt.so
    if [ -f "$TARGET_ROOTFS_DIR/root/dlcv/bin/librknnrt.so" ]; then
        sudo cp -f "$TARGET_ROOTFS_DIR/root/dlcv/bin/librknnrt.so" "$TARGET_ROOTFS_DIR/usr/lib/librknnrt.so"
        sudo chmod 644 "$TARGET_ROOTFS_DIR/usr/lib/librknnrt.so"
    fi

    # Set executable permissions
    sudo chmod +x "$TARGET_ROOTFS_DIR/root/dlcv/bin/pressure_test"         "$TARGET_ROOTFS_DIR/root/dlcv/bin/rtop"         "$TARGET_ROOTFS_DIR/root/dlcv/bin/debug"         "$TARGET_ROOTFS_DIR/root/dlcv/bin/dlcv_infer_cpp_qt_demo"         "$TARGET_ROOTFS_DIR/root/dlcv/bin/ai_model_accelerator.bin" 2>/dev/null || true

    # Configure activate script LD_LIBRARY_PATH
    ACTIVATE_FILE="$TARGET_ROOTFS_DIR/root/dlcv/bin/activate"
    if [ -f "$ACTIVATE_FILE" ] && ! grep -qF "DLCV_LDPATH" "$ACTIVATE_FILE" 2>/dev/null; then
        sudo tee -a "$ACTIVATE_FILE" >/dev/null << 'ACTIVATE_EOF'

# DLCV local library path
DLCV_LDPATH="/root/dlcv/bin/lib:/root/dlcv/lib:/root/dlcv/bin"
if [ -z "${LD_LIBRARY_PATH-}" ] ; then
    LD_LIBRARY_PATH="$DLCV_LDPATH"
else
    LD_LIBRARY_PATH="$DLCV_LDPATH:$LD_LIBRARY_PATH"
fi
export LD_LIBRARY_PATH
ACTIVATE_EOF
    fi

    # Copy Sentinel driver deb to /tmp for chroot install
    sudo bash -c 'find "$0/root/dlcv/bin" -maxdepth 1 -name "aksusbd_*_arm64.deb" -exec cp {} "$0/tmp/" \; ' "$TARGET_ROOTFS_DIR"

    # Copy SenseShield driver deb to /tmp for chroot install
    SENSESHIELD_DEB="/share/4-智能相机/0-环境安装/senseshield-lcc-2.7.5.69040-arm64.deb"
    if [ -f "$SENSESHIELD_DEB" ]; then
        sudo cp -f "$SENSESHIELD_DEB" "$TARGET_ROOTFS_DIR/tmp/"
    fi

    # Copy install_kimi.sh to /scripts for chroot install
    if [ -f "scripts/install_kimi.sh" ]; then
        sudo mkdir -p "$TARGET_ROOTFS_DIR/scripts"
        sudo cp -f "scripts/install_kimi.sh" "$TARGET_ROOTFS_DIR/scripts/"
    fi

    # Fix ownership
    sudo chown -hR 0:0 $TARGET_ROOTFS_DIR/root/dlcv
else
    echo -e "\033[41;36m DLCV environment extraction failed \033[0m"
    sudo rm -rf "$TARGET_ROOTFS_DIR/root/dlcv_extract_tmp"
fi

echo -e "\033[47;36m Change root.....................\033[0m"
ID=$(stat --format %u $TARGET_ROOTFS_DIR)

cat << EOF | sudo chroot $TARGET_ROOTFS_DIR /bin/bash

# Fixup owners
if [ "$ID" -ne 0 ]; then
    find / -user $ID -exec chown -h 0:0 {} \;
fi
for u in \$(ls /home/); do
    chown -h -R \$u:\$u /home/\$u
done

ln -sf /run/resolvconf/resolv.conf /etc/resolv.conf

echo "deb http://mirrors.ustc.edu.cn/debian/ bookworm-backports main contrib" >> /etc/apt/sources.list
echo "deb-src http://mirrors.ustc.edu.cn/debian/ bookworm-backports main contrib" >> /etc/apt/sources.list

# Add embedfire packages source
mkdir -p /etc/apt/keyrings
curl -fsSL https://Embedfire.github.io/keyfile | gpg --dearmor -o /etc/apt/keyrings/embedfire.gpg
chmod a+r /etc/apt/keyrings/embedfire.gpg
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/embedfire.gpg] https://cloud.embedfire.com/mirrors/ebf-debian carp-lbc main" | tee /etc/apt/sources.list.d/embedfire-lbc.list > /dev/null
if [ $MIRROR ]; then
    echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/embedfire.gpg] https://cloud.embedfire.com/mirrors/ebf-debian $MIRROR main" | tee /etc/apt/sources.list.d/embedfire-$MIRROR.list > /dev/null
fi

export LC_ALL=C.UTF-8

apt-get update
apt-get upgrade -y

export APT_INSTALL="apt-get install -fy --allow-downgrades"

echo -e "\033[47;36m ---------- LubanCat -------- \033[0m"
\${APT_INSTALL} dialog toilet u-boot-tools edid-decode logrotate fire-config lbc-test usbmount

# pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple setuptools wheel
# pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple python-periphery Adafruit-Blinka

passwd root <<IEOF
root
root
IEOF

systemctl disable apt-daily.service
systemctl disable apt-daily.timer

systemctl disable apt-daily-upgrade.timer
systemctl disable apt-daily-upgrade.service

# set localtime
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
if [[ "$TARGET" == "gnome" ]]; then
    \${APT_INSTALL} mpv fire-config-gui
    #Desktop background picture
    ln -sf /usr/share/images/desktop-base/lubancat-wallpaper.png /etc/alternatives/desktop-background
elif [[ "$TARGET" == "xfce" ]]; then
    \${APT_INSTALL} mpv fire-config-gui
    #Desktop background picture
    chown -hR dlcv:dlcv /home/dlcv/.config || true
    ln -sf /usr/share/images/desktop-base/lubancat-wallpaper.png /etc/alternatives/desktop-background
elif [[ "$TARGET" == "lxde" ]]; then
    \${APT_INSTALL} mpv fire-config-gui
    #Desktop background picture
    # ln -sf /usr/share/desktop-base/images/lubancat-wallpaper.png 
elif [ "$TARGET" == "lite" ]; then
    \${APT_INSTALL} bluez bluez-tools
fi

\${APT_INSTALL} /packages/install_packages/*.deb

\${APT_INSTALL} /boot/kerneldeb/* || true

echo -e "\033[47;36m ----- power management ----- \033[0m"
\${APT_INSTALL} pm-utils triggerhappy bsdmainutils
cp /etc/Powermanager/triggerhappy.service  /lib/systemd/system/triggerhappy.service
sed -i "s/#HandlePowerKey=.*/HandlePowerKey=ignore/" /etc/systemd/logind.conf

echo -e "\033[47;36m ---------- Install common tools -------- \033[0m"
\${APT_INSTALL} aptitude cifs-utils graphviz nano nload p7zip-full screen tmux tree

echo -e "\033[47;36m ----------- RGA  ----------- \033[0m"
\${APT_INSTALL} /packages/rga2/*.deb


if [[ "$TARGET" == "gnome" || "$TARGET" == "xfce" || "$TARGET" == "lxde" ]]; then
    echo -e "\033[47;36m ------ Setup Video---------- \033[0m"
    \${APT_INSTALL} gstreamer1.0-plugins-bad gstreamer1.0-plugins-base gstreamer1.0-plugins-ugly gstreamer1.0-tools gstreamer1.0-alsa \
    gstreamer1.0-plugins-base-apps

    \${APT_INSTALL} /packages/mpp/*
    \${APT_INSTALL} /packages/gst-rkmpp/*.deb
    \${APT_INSTALL} /packages/gstreamer/*.deb
    \${APT_INSTALL} /packages/gst-plugins-base1.0/*.deb
    \${APT_INSTALL} /packages/gst-plugins-bad1.0/*.deb
    \${APT_INSTALL} /packages/gst-plugins-good1.0/*.deb
elif [ "$TARGET" == "lite" ]; then
    echo -e "\033[47;36m ------ Setup Video---------- \033[0m"
    \${APT_INSTALL} /packages/mpp/*
    \${APT_INSTALL} /packages/gst-rkmpp/*.deb
fi

if [[ "$TARGET" == "gnome" || "$TARGET" == "xfce" || "$TARGET" == "lxde" ]]; then
    echo -e "\033[47;36m ----- Install Camera ------- \033[0m"
    \${APT_INSTALL} cheese v4l-utils
    \${APT_INSTALL} /packages/libv4l/*.deb
    \${APT_INSTALL} /packages/cheese/*.deb

    echo -e "\033[47;36m ----- Install Xserver------- \033[0m"
    \${APT_INSTALL} /packages/xserver/*.deb

    apt-mark hold xserver-common xserver-xorg-core xserver-xorg-legacy

    # echo -e "\033[47;36m ------ Install openbox ----- \033[0m"
    # \${APT_INSTALL} /packages/openbox/*.deb

    echo -e "\033[47;36m ------ update chromium ----- \033[0m"
    \${APT_INSTALL} /packages/chromium/*.deb
fi

echo -e "\033[47;36m ------- Install libdrm ------ \033[0m"
\${APT_INSTALL} /packages/libdrm/*.deb

if [[ "$TARGET" == "gnome" || "$TARGET" == "xfce" || "$TARGET" == "lxde" ]]; then
    echo -e "\033[47;36m ------ libdrm-cursor -------- \033[0m"
    \${APT_INSTALL} /packages/libdrm-cursor/*.deb

    echo -e "\033[47;36m --------  blueman  ---------- \033[0m"
    \${APT_INSTALL} blueman
    echo exit 101 > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d
    \${APT_INSTALL} blueman
    rm -f /usr/sbin/policy-rc.d

    \${APT_INSTALL} /packages/blueman/*.deb

    if [ "$VERSION" == "debug" ]; then
    echo -e "\033[47;36m ------ Install glmark2 ------ \033[0m"
    \${APT_INSTALL} /packages/glmark2/*.deb
    fi
fi

if [ -e "/usr/lib/aarch64-linux-gnu" ] ;
then
echo -e "\033[47;36m ------- move rknpu2 --------- \033[0m"
mv /packages/rknpu2/rknpu2.tar  /
fi

echo -e "\033[47;36m ----- Install rktoolkit ----- \033[0m"
\${APT_INSTALL} /packages/rktoolkit/*.deb

if [[ "$TARGET" == "gnome" || "$TARGET" == "xfce" || "$TARGET" == "lxde" ]]; then
    echo -e "\033[47;36m Install Chinese fonts.................... \033[0m"
    # Uncomment zh_CN.UTF-8 for inclusion in generation
    sed -i 's/^# *\(zh_CN.UTF-8\)/\1/' /etc/locale.gen
    echo "LANG=zh_CN.UTF-8" >> /etc/default/locale

    # Generate locale
    locale-gen
fi

\${APT_INSTALL} ttf-wqy-zenhei fonts-aenigma
\${APT_INSTALL} xfonts-intl-chinese

if [[ "$TARGET" == "gnome" || "$TARGET" == "xfce" || "$TARGET" == "lxde" ]]; then
    echo -e "\033[47;36m -------     ibus    -------- \033[0m"
    \${APT_INSTALL} ibus ibus-libpinyin

    # echo -e "\033[47;36m -------   pipewire  -------- \033[0m"
    # \${APT_INSTALL} pipewire pipewire-pulse pipewire-alsa libspa-0.2-bluetooth
    # \${APT_INSTALL} /packages/pipewire/*.deb
    # \${APT_INSTALL} /packages/wireplumber/*.deb
    # find /usr/lib/systemd/ -name "wireplumber*.service" | xargs sed -i "/Environment/s/$/ DISPLAY=:0/"

    # fix pipewire output control
    \${APT_INSTALL} pulseaudio pulseaudio-utils pavucontrol
    apt purge -f -y pipewire-pulse

    echo -e "\033[47;36m ----- Wayland/Weston ------- \033[0m"
    \${APT_INSTALL} libseat-dev
    \${APT_INSTALL} /packages/weston/*.deb
    \${APT_INSTALL} /packages/wayland/*.deb
fi

# HACK debian11.3 to fix bug
#\${APT_INSTALL} fontconfig --reinstall

# HACK to disable the kernel logo on bootup
#sed -i "/exit 0/i \ echo 3 > /sys/class/graphics/fb0/blank" /etc/rc.local

#---------------DLCV Environment Installation--------------

echo -e "\033[47;36m ---------- Install DLCV runtime dependencies -------- \033[0m"
\${APT_INSTALL} libopencv-dev libgomp1 qtbase5-dev python3-gi gir1.2-gstreamer-1.0 gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good 7zip build-essential cmake ninja-build patchelf ccache libopencv-contrib-dev libsodium-dev qtbase5-dev-tools qt5-qmake qt6-base-dev libqt5widgets5 libqt5gui5 libqt5core5a libgl1-mesa-dev python3-dev zram-tools chromium-x11 || true

echo -e "\033[47;36m ---------- Install Sentinel dongle driver ---------- \033[0m"
DONGLE_DEB=\$(find /tmp -maxdepth 1 -name 'aksusbd_*_arm64.deb' | head -n 1)
if [ -n "\$DONGLE_DEB" ]; then
    dpkg -i "\$DONGLE_DEB" || apt-get install -f -y
    systemctl enable hasplmd.service 2>/dev/null || true
    rm -f "\$DONGLE_DEB"
fi

echo -e "\033[47;36m ---------- Install SenseShield dongle driver ---------- \033[0m"
SENSESHIELD_DEB=\$(find /tmp -maxdepth 1 -name 'senseshield-lcc-*-arm64.deb' | head -n 1)
if [ -n "\$SENSESHIELD_DEB" ]; then
    dpkg -i "\$SENSESHIELD_DEB" || apt-get install -f -y
    systemctl enable senseshield.service 2>/dev/null || true
    systemctl enable virboxlcc.service 2>/dev/null || true
    rm -f "\$SENSESHIELD_DEB"
fi

ldconfig

# Fix gi module symlink
if [ -d /usr/lib/python3/dist-packages/gi ] && [ -d /root/dlcv/lib/python3.11/site-packages ]; then
    rm -f /root/dlcv/lib/python3.11/site-packages/gi
    ln -sf /usr/lib/python3/dist-packages/gi /root/dlcv/lib/python3.11/site-packages/gi
fi

# Fix DLCV environment ownership
chown -hR dlcv:dlcv /root/dlcv 2>/dev/null || true

echo -e "\033[47;36m ---------- Configure ccache ---------- \033[0m"
ccache --max-size=5G 2>/dev/null || true

# mark package to hold
apt list --installed | grep -v oldstable | cut -d/ -f1 | xargs apt-mark hold

#---------------DLCV Customization--------------

echo -e "\033[47;36m ---------- DLCV User/Hostname Setup -------- \033[0m"
# Ensure hostname is DLCVCAM
echo "DLCVCAM" > /etc/hostname
sed -i 's/127.0.1.1.*/127.0.1.1\tDLCVCAM/' /etc/hosts

# Ensure dlcv user exists with correct password and groups
if ! id "dlcv" &>/dev/null; then
    if id "cat" &>/dev/null; then
        echo "I: renaming cat user to dlcv"
        usermod -l dlcv cat
        usermod -d /home/dlcv -m dlcv
        groupmod -n dlcv cat 2>/dev/null || true
    else
        echo "I: creating dlcv user"
        adduser --gecos dlcv --disabled-password dlcv
        usermod -a -G adm,dialout,cdrom,audio,dip,video,plugdev,bluetooth,pulse-access,sudo,systemd-journal,netdev,staff dlcv
    fi
fi
echo "dlcv:dlcvai" | chpasswd

# Remove old cat user if still exists (after rename or if it was separate)
if id "cat" &>/dev/null; then
    userdel -r cat 2>/dev/null || true
fi

# Fix dlcv home ownership
chown -hR dlcv:dlcv /home/dlcv 2>/dev/null || true

# Update gdm3 autologin to dlcv and force Xorg (disable Wayland for x11vnc compatibility)
if [ -e /etc/gdm3/daemon.conf ]; then
    sed -i "s|^#*\\s*AutomaticLoginEnable = .*|AutomaticLoginEnable = true|" /etc/gdm3/daemon.conf
    sed -i "s|^#*\\s*AutomaticLogin = .*|AutomaticLogin = dlcv|" /etc/gdm3/daemon.conf
    sed -i "s|^#*\\s*WaylandEnable = .*|WaylandEnable = false|" /etc/gdm3/daemon.conf
fi

echo -e "\033[47;36m ---------- Install zsh / btop / x11vnc / gnome-terminal -------- \033[0m"
\${APT_INSTALL} zsh git curl wget btop x11vnc gnome-terminal

echo -e "\033[47;36m ---------- Install GitHub CLI (gh) -------- \033[0m"
# Debian 官方仓库 gh 版本过旧（如 2.23.0），会导致 gh pr edit 因 GraphQL 弃用警告失败，
# 因此使用 GitHub 官方 apt 源安装最新版。
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt-get update
\${APT_INSTALL} gh

echo -e "\033[47;36m ---------- Install oh-my-zsh -------- \033[0m"
# Install oh-my-zsh for dlcv user
if [ -d /home/dlcv ]; then
    (
        export HOME=/home/dlcv
        export RUNZSH=no
        export CHSH=no
        export ZSH=/home/dlcv/.oh-my-zsh
        sh -c "\$(curl --retry 3 --connect-timeout 10 -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" || \
            sh -c "\$(curl --retry 3 --connect-timeout 10 -fsSL https://gitee.com/mirrors/oh-my-zsh/raw/master/tools/install.sh)"
    )
    if [ -f /home/dlcv/.zshrc ]; then
        sed -i 's/^# DISABLE_AUTO_UPDATE="true"/DISABLE_AUTO_UPDATE="true"/' /home/dlcv/.zshrc
        sed -i 's/^DISABLE_AUTO_UPDATE="false"/DISABLE_AUTO_UPDATE="true"/' /home/dlcv/.zshrc
        echo "zstyle ':omz:update' mode disabled" >> /home/dlcv/.zshrc
    fi
    chown -hR dlcv:dlcv /home/dlcv/.oh-my-zsh 2>/dev/null || true
    chown dlcv:dlcv /home/dlcv/.zshrc 2>/dev/null || true
fi

# Install oh-my-zsh for root user
export ZSH=/root/.oh-my-zsh
sh -c "\$(curl --retry 3 --connect-timeout 10 -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" || \
    sh -c "\$(curl --retry 3 --connect-timeout 10 -fsSL https://gitee.com/mirrors/oh-my-zsh/raw/master/tools/install.sh)"
if [ -f /root/.zshrc ]; then
    sed -i 's/^# DISABLE_AUTO_UPDATE="true"/DISABLE_AUTO_UPDATE="true"/' /root/.zshrc
    sed -i 's/^DISABLE_AUTO_UPDATE="false"/DISABLE_AUTO_UPDATE="true"/' /root/.zshrc
    echo "zstyle ':omz:update' mode disabled" >> /root/.zshrc
fi

# Set default shell to zsh for dlcv and root
chsh -s /bin/zsh dlcv || true
chsh -s /bin/zsh root || true

# Activate environment in shell configs (must run after oh-my-zsh and user creation)
ACTIVATE_LINE="source /root/dlcv/bin/activate"
for RC in /root/.bashrc /root/.zshrc /home/dlcv/.bashrc /home/dlcv/.zshrc; do
    touch "\$RC" 2>/dev/null || true
    if ! grep -qF "\$ACTIVATE_LINE" "\$RC" 2>/dev/null; then
        echo "\$ACTIVATE_LINE" >> "\$RC"
    fi
done

echo -e "\033[47;36m ---------- Configure Python environment for non-interactive SSH ---------- \033[0m"
# Create /root/.zshenv for non-interactive zsh to export PATH/LD_LIBRARY_PATH
cat > /root/.zshenv << 'ZSHEV_EOF'
if [[ ! -o interactive ]]; then
    export VIRTUAL_ENV='/root/dlcv'
    export PATH="/root/dlcv/bin:$PATH"
    export LD_LIBRARY_PATH="/root/dlcv/lib:/root/dlcv/bin:/root/dlcv/lib/python3.11/site-packages/dlcvpro_infer:/root/dlcv/lib/python3.11/site-packages/torch/lib"
fi
ZSHEV_EOF

# Create /usr/local/bin/python wrapper with LF line endings
cat > /usr/local/bin/python << 'PYTHON_EOF'
#!/bin/bash
exec /root/dlcv/bin/python3 "$@"
PYTHON_EOF
chmod +x /usr/local/bin/python

echo -e "\033[47;36m ---------- Update dconf for GNOME settings -------- \033[0m"
dconf update

echo -e "\033[47;36m ---------- Setup VNC password and enable x11vnc service -------- \033[0m"
# Pre-generate VNC password for dlcv user
mkdir -p /home/dlcv/.vnc
x11vnc -storepasswd "dlcvai" /home/dlcv/.vnc/passwd
chown -R dlcv:dlcv /home/dlcv/.vnc
chmod 600 /home/dlcv/.vnc/passwd
chmod 755 /home/dlcv/.vnc

# Enable x11vnc-dlcv service for autostart
# Services are placed in /etc/systemd/user/ so --global enable works correctly
systemctl --global enable x11vnc-dlcv.service 2>/dev/null || true
# Also create symlink manually in case --global enable fails in chroot
mkdir -p /etc/systemd/user/graphical-session.target.wants
ln -sf /etc/systemd/user/x11vnc-dlcv.service /etc/systemd/user/graphical-session.target.wants/x11vnc-dlcv.service

echo -e "\033[47;36m ---------- Setup SSH authorized_keys -------- \033[0m"
# Setup SSH authorized_keys for passwordless login
if [ -f /authorized_keys ]; then
    mkdir -p /root/.ssh
    cp /authorized_keys /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys

    mkdir -p /home/dlcv/.ssh
    cp /authorized_keys /home/dlcv/.ssh/authorized_keys
    chmod 700 /home/dlcv/.ssh
    chmod 600 /home/dlcv/.ssh/authorized_keys
    chown -hR dlcv:dlcv /home/dlcv/.ssh
    rm -f /authorized_keys
fi

#---------------Custom Script--------------
systemctl mask systemd-networkd-wait-online.service
systemctl mask NetworkManager-wait-online.service
rm /lib/systemd/system/wpa_supplicant@.service

echo -e "\033[47;36m ---------- Configure zram and swap ---------- \033[0m"
# zram: 25% of memory (~1GB on RK3576 4GB)
\${APT_INSTALL} zram-tools 2>/dev/null || true
cat > /etc/default/zramswap << 'ZRAM_EOF'
ALGO=zstd
PERCENT=25
ZRAM_EOF
systemctl enable zramswap.service 2>/dev/null || true

# Dynamic swap setup: 25% of RAM, max 2GB
# Do NOT create fixed-size swapfile in rootfs; use systemd oneshot service
cat > /usr/local/bin/setup-swap.sh << 'SWAP_EOF'
#!/bin/bash
set -e
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
SWAP_SIZE_MB=$(( TOTAL_MEM_MB / 4 ))
[ "$SWAP_SIZE_MB" -gt 2048 ] && SWAP_SIZE_MB=2048

if [ -f /swapfile ]; then
    CURRENT_SIZE_MB=$(stat -c %s /swapfile | awk '{print int($1/1024/1024)}')
    if [ "$CURRENT_SIZE_MB" != "$SWAP_SIZE_MB" ]; then
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
    fi
fi

if [ ! -f /swapfile ]; then
    fallocate -l ${SWAP_SIZE_MB}M /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
fi
SWAP_EOF
chmod +x /usr/local/bin/setup-swap.sh

cat > /etc/systemd/system/dlcv-swap.service << 'SERVICE_EOF'
[Unit]
Description=DLCV Dynamic Swap Setup
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-swap.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl enable dlcv-swap.service 2>/dev/null || true

# Enable CamOS services
systemctl enable camos.service camos-admin.service 2>/dev/null || true

echo -e "\033[47;36m ---------- Install kimi-cli ---------- \033[0m"
if [ -f /scripts/install_kimi.sh ]; then
    bash /scripts/install_kimi.sh || true
    rm -f /scripts/install_kimi.sh
fi

echo -e "\033[47;36m ---------- Configure kimi-web service ---------- \033[0m"
# overlay 已将 /etc/systemd/system/kimi-web.service 复制到目标系统
systemctl daemon-reload
# 默认不启用 kimi-web，用户按需手动执行 systemctl enable --now kimi-web

# Add alias to zshrc for root and dlcv
ALIAS_LINE='alias kimi_url="journalctl -u kimi-web | grep ➜ | tail -2"'
for ZRC in /root/.zshrc /home/dlcv/.zshrc; do
    if [ -f "$ZRC" ] && ! grep -qF "alias kimi_url=" "$ZRC" 2>/dev/null; then
        echo "$ALIAS_LINE" >> "$ZRC"
    fi
done

#---------------Clean--------------
if [ -e "/usr/lib/arm-linux-gnueabihf/dri" ] ;
then
    # Only preload libdrm-cursor for X
    sed -i "1aexport LD_PRELOAD=/usr/lib/arm-linux-gnueabihf/libdrm-cursor.so.1" /usr/bin/X
    cd /usr/lib/arm-linux-gnueabihf/dri/
    cp kms_swrast_dri.so swrast_dri.so rockchip_dri.so /
    rm /usr/lib/arm-linux-gnueabihf/dri/*.so
    mv /*.so /usr/lib/arm-linux-gnueabihf/dri/
elif [ -e "/usr/lib/aarch64-linux-gnu/dri" ];
then
    # Only preload libdrm-cursor for X
    sed -i "1aexport LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libdrm-cursor.so.1" /usr/bin/X
    cd /usr/lib/aarch64-linux-gnu/dri/
    cp kms_swrast_dri.so swrast_dri.so rockchip_dri.so /
    rm /usr/lib/aarch64-linux-gnu/dri/*.so
    mv /*.so /usr/lib/aarch64-linux-gnu/dri/
    rm /etc/profile.d/qt.sh
fi
cd -

# Cleanup documentation to reduce image size
rm -rf /usr/share/doc/*
rm -rf /usr/share/info/*

# Cleanup locales: keep only English and Chinese
if [ -d /usr/lib/locale ]; then
    find /usr/lib/locale -maxdepth 1 -mindepth 1 -type d ! -name "en_*" ! -name "zh_*" -exec rm -rf {} + 2>/dev/null || true
fi
if [ -d /usr/share/locale ]; then
    find /usr/share/locale -maxdepth 1 -mindepth 1 -type d ! -name "en*" ! -name "zh*" -exec rm -rf {} + 2>/dev/null || true
fi

rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/
rm -rf /packages/
rm -rf /boot/*
rm -rf /sha256sum*

EOF

TARGET=$TARGET SOC=$SOC ./mk-image.sh 
