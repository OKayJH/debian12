#!/bin/bash
# camos-lla-keepalive: 确保以太网口始终持有其确定性链路本地 fallback 地址，
# 独立于 NetworkManager / DHCP。
#
# 背景：NM 的 method=auto(DHCP) + may-fail=yes 在直连（无 DHCP）时不可靠——
# DHCP 超时失败会使整个连接 failed 并移除所有地址（含静态 LLA），进入 fail-loop，
# 导致设备在直连下大多时候无 IP、GVCP 不可发现。本看门狗每秒在内核层补回 LLA，
# 使 camos 发现始终可响应（camos 读内核接口状态）。
#
# LLA 由接口 MAC 的 md5 确定性派生，与 dlcvcam-init.sh::generate_link_local_ip 同算法。
IFACE="${1:-eth0}"

derive_lla() {
    local mac="$1"
    python3 -c "
import sys, hashlib
mac_bytes = bytes.fromhex(sys.argv[1].replace(':', ''))
h = hashlib.md5(mac_bytes).digest()
v = (h[0] << 8) | h[1]
if v in (0, 0xFFFF):
    v = 0x1234
print(f'169.254.{v >> 8}.{v & 0xFF}')
" "$mac" 2>/dev/null
}

while true; do
    if ip link show "$IFACE" 2>/dev/null | grep -q "LOWER_UP"; then
        mac=$(cat /sys/class/net/"$IFACE"/address 2>/dev/null)
        lla=$(derive_lla "$mac" 2>/dev/null)
        if [ -n "$lla" ]; then
            if ! ip -4 addr show "$IFACE" 2>/dev/null | grep -qw "$lla"; then
                ip addr add "$lla/16" dev "$IFACE" 2>/dev/null
            fi
        fi
    fi
    sleep 1
done
