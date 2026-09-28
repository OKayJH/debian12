## 简介

A set of shell scripts that will build GNU/Linux distribution rootfs image
for rockchip platform.

## 适用板卡

- 使用RK3576处理器的LubanCat板卡

## 安装依赖

构建主机环境最低要求Ubuntu20.04及以上版本，推荐使用Ubuntu22.04

```
sudo apt-get install binfmt-support qemu-user-static
sudo dpkg -i ubuntu-build-service/packages/*
sudo apt-get install -f
```

## 构建 Debian12 bookworm 镜像（仅支持64bit）

- lite：控制台版，无桌面
- xfce：桌面版，使用xfce4桌面套件
- lxde：桌面版，使用lxde桌面套件
- gnome：桌面版，使用gnome桌面套件


#### step1.构建基础 Debian 系统。

```
# 运行以下脚本，根据提示选择要构建的版本
./mk-base-debian.sh
```
#### step2.添加 rk overlay 层,并打包linaro-rootfs镜像

```
# 根据提示选择要构建桌面版本和SOC版本

VERSION=debug ./mk-bookworm-rootfs.sh

```


---

## Cross Compile for ARM Debian

[Docker + Multiarch](http://opensource.rock-chips.com/wiki_Cross_Compile#Docker)

## Package Code Base

Please apply [those patches](https://github.com/rockchip-linux/rk-rootfs-build/tree/master/packages-patches) to release code base before rebuilding!

## License information

Please see [debian license](https://www.debian.org/legal/licenses/)

## FAQ

- noexec or nodev issue
noexec or nodev issue /usr/share/debootstrap/functions: line 1450:
../rootfs/ubuntu-build-service/bookworm-desktop-arm64/chroot/test-dev-null:
Permission denied E: Cannot install into target
...
mounted with noexec or nodev

Solution: mount -o remount,exec,dev xxx (xxx is the mount place), then rebuild it.

## 智能相机开机网络配置

`overlay/usr/local/bin/dlcvcam-init.sh` 由 `rockchip.sh` 在开机时调用。
它只在 `/etc/NetworkManager/system-connections/<网卡>.nmconnection` 不存在时
创建 DHCP + 链路本地地址默认配置；已有配置保持不变，包括静态 IP、DHCP 自定义参数和 UUID。
用户通过 CamOS / NetworkManager 保存的配置不能在下次开机时被默认模板覆盖。

不改动主机网络的回归测试（Linux，Python 3 标准库 + Bash）：

```bash
python3 -m unittest discover -s tests -v
bash -n overlay/usr/local/bin/dlcvcam-init.sh
bash -n scripts/install-network-init.sh
```

现有设备可通过专用入口只更新初始化脚本，无需构建或刷写整个镜像：

```bash
sudo bash scripts/install-network-init.sh
```

安装前备份设备原脚本和 NetworkManager 配置，并确认测试设备没有被其他任务占用。
该入口不会执行初始化、修改当前连接或自动重启；安装后应使用已确认未占用的测试 IP，
通过 CamOS 修改并重启设备，核对地址、网络配置和连接 UUID 是否保留。
不要在开发机直接执行完整初始化脚本，也不要将设备备份或访问凭据提交到仓库。
