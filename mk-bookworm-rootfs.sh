#!/bin/bash -e

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

echo -e "\033[47;36m Change root.....................\033[0m"
ID=$(stat --format %u $TARGET_ROOTFS_DIR)

cat << EOF | sudo chroot $TARGET_ROOTFS_DIR

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

# Update gdm3 autologin to dlcv
if [ -e /etc/gdm3/daemon.conf ]; then
    sed -i "s|^#*\\s*AutomaticLoginEnable = .*|AutomaticLoginEnable = true|" /etc/gdm3/daemon.conf
    sed -i "s|^#*\\s*AutomaticLogin = .*|AutomaticLogin = dlcv|" /etc/gdm3/daemon.conf
fi

echo -e "\033[47;36m ---------- Install zsh / btop / x11vnc / gnome-terminal -------- \033[0m"
\${APT_INSTALL} zsh git curl wget btop x11vnc gnome-terminal

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
fi

# Set default shell to zsh for dlcv and root
chsh -s /bin/zsh dlcv || true
chsh -s /bin/zsh root || true

echo -e "\033[47;36m ---------- Update dconf for GNOME settings -------- \033[0m"
dconf update

echo -e "\033[47;36m ---------- Enable x11vnc user services -------- \033[0m"
# Enable x11vnc services for autostart
# Services are placed in /etc/systemd/user/ so --global enable works correctly
systemctl --global enable x11vnc-dlcv.service 2>/dev/null || true
systemctl --global enable x11vnc-root.service 2>/dev/null || true

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

rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/
rm -rf /packages/
rm -rf /boot/*
rm -rf /sha256sum*

EOF

TARGET=$TARGET SOC=$SOC ./mk-image.sh 
