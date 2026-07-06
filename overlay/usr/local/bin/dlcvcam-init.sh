#!/bin/bash
#
# DLCVCAM Platform Network Init
# - Sets unique hostname based on hardware CPU ID (OTP)
# - Sets unique MAC address per interface based on CPU ID
# - Persists hostname to /etc/hostname and /etc/hosts
# - Generates udev rules for hotplug interfaces
#

set -e

OTP_PATH="/sys/bus/nvmem/devices/rockchip-otp0/nvmem"
OTP_OFFSET=10   # 0x0A
OTP_LENGTH=16   # 16 bytes CPU ID

# --- 1. Read CPU ID from OTP ---
read_cpu_id() {
    local path="$1"
    local offset="$2"
    local length="$3"

    if [ -r "$path" ]; then
        xxd -p -l "$length" -s "$offset" "$path" 2>/dev/null | tr -d '\n'
    else
        echo ""
    fi
}

CPU_ID_HEX=$(read_cpu_id "$OTP_PATH" "$OTP_OFFSET" "$OTP_LENGTH")

# Fallback: try to find any readable nvmem device
if [ -z "$CPU_ID_HEX" ] || [ "${#CPU_ID_HEX}" -lt 32 ]; then
    for fallback in /sys/bus/nvmem/devices/*/nvmem; do
        if [ -r "$fallback" ]; then
            CPU_ID_HEX=$(read_cpu_id "$fallback" "$OTP_OFFSET" "$OTP_LENGTH")
            if [ -n "$CPU_ID_HEX" ] && [ "${#CPU_ID_HEX}" -ge 32 ]; then
                break
            fi
        fi
    done
fi

# Fallback 2: read Serial from /proc/cpuinfo (kernel sets this when CONFIG_NO_GKI=y)
if [ -z "$CPU_ID_HEX" ] || [ "${#CPU_ID_HEX}" -lt 32 ]; then
    PROC_SERIAL=$(awk '/^Serial/{print $3}' /proc/cpuinfo 2>/dev/null | head -1)
    if [ -n "$PROC_SERIAL" ] && [ "${#PROC_SERIAL}" -ge 16 ]; then
        # /proc/cpuinfo Serial is already a CRC32-derived 16-hex string.
        # Pad it to 32 hex chars (16 bytes) for consistent processing.
        CPU_ID_HEX="${PROC_SERIAL}${PROC_SERIAL}"
        CPU_ID_HEX="${CPU_ID_HEX:0:32}"
        echo "dlcvcam-init: Using Serial from /proc/cpuinfo" >&2
    fi
fi

# Final fallback: zeros (allows boot to continue, but not unique)
if [ -z "$CPU_ID_HEX" ] || [ "${#CPU_ID_HEX}" -lt 32 ]; then
    echo "dlcvcam-init: Warning: failed to read CPU ID from OTP or /proc/cpuinfo, using fallback" >&2
    CPU_ID_HEX="00000000000000000000000000000000"
fi

# --- 2. Python helper: compute hostname and per-interface MAC ---
PYTHON_HELPER=$(cat <<'PY'
import sys
import binascii
import hashlib

def main():
    cpu_id_hex = sys.argv[1]
    ifaces = sys.argv[2:]

    try:
        cpu_id = bytes.fromhex(cpu_id_hex)
    except Exception:
        cpu_id = b'\x00' * 16

    if len(cpu_id) < 16:
        cpu_id = cpu_id.ljust(16, b'\x00')

    # Hostname: CRC32 low 16 bits as 4-digit hex
    crc = binascii.crc32(cpu_id) & 0xFFFFFFFF
    hostname = "DLCVCAM-{:04x}".format(crc & 0xFFFF)

    # MAC per interface: SHA256(CPU_ID + iface_name), prefix 02:
    results = {"hostname": hostname}
    for iface in ifaces:
        seed = hashlib.sha256(cpu_id + iface.encode('utf-8')).digest()
        mac = "{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}".format(
            0x02, seed[0], seed[1], seed[2], seed[3], seed[4]
        )
        results[iface] = mac

    # Output as key=value pairs
    for k, v in results.items():
        print("{}={}".format(k, v))

if __name__ == "__main__":
    main()
PY
)

# Collect existing ethernet-like interfaces
IFACES=$(ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|enp|ens|usb)' | sort | tr '\n' ' ' || true)

# Run Python helper
OUTPUT=$(python3 -c "$PYTHON_HELPER" "$CPU_ID_HEX" $IFACES 2>/dev/null || true)

if [ -z "$OUTPUT" ]; then
    echo "dlcvcam-init: Warning: python3 helper failed, skipping network init" >&2
    exit 0
fi

HOSTNAME=$(echo "$OUTPUT" | grep '^hostname=' | cut -d'=' -f2-)

# --- 3. Set and persist hostname ---
if [ -n "$HOSTNAME" ]; then
    CURRENT_HOSTNAME=$(cat /etc/hostname 2>/dev/null || echo "")
    if [ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]; then
        echo "$HOSTNAME" > /etc/hostname
        hostname "$HOSTNAME" 2>/dev/null || true
        # Update /etc/hosts 127.0.1.1 line
        if grep -q '127.0.1.1' /etc/hosts 2>/dev/null; then
            sed -i "s/127.0.1.1.*/127.0.1.1\t${HOSTNAME}/" /etc/hosts
        else
            echo -e "127.0.1.1\t${HOSTNAME}" >> /etc/hosts
        fi
        echo "dlcvcam-init: Hostname set to ${HOSTNAME}"
    fi
fi

# --- 4. Set MAC for existing interfaces ---
for iface in $IFACES; do
    MAC=$(echo "$OUTPUT" | grep "^${iface}=" | cut -d'=' -f2-)
    if [ -z "$MAC" ]; then
        continue
    fi

    IFACE_PATH="/sys/class/net/${iface}"
    if [ ! -d "$IFACE_PATH" ]; then
        continue
    fi

    CURRENT_MAC=$(cat "${IFACE_PATH}/address" 2>/dev/null || echo "")
    if [ "$CURRENT_MAC" = "$MAC" ]; then
        continue
    fi

    # Try to set MAC (bring down, set, bring up)
    ip link set dev "$iface" down 2>/dev/null || true
    if ip link set dev "$iface" address "$MAC" 2>/dev/null; then
        echo "dlcvcam-init: MAC set for ${iface}: ${MAC}"
    else
        echo "dlcvcam-init: Warning: failed to set MAC for ${iface}" >&2
    fi
    ip link set dev "$iface" up 2>/dev/null || true
done

# --- 5. Generate udev rule for future/hotplug interfaces ---
UDEV_RULE="/etc/udev/rules.d/75-dlcvcam-mac.rules"
UDEV_HELPER="/usr/local/bin/dlcvcam-set-mac.sh"

cat > "$UDEV_HELPER" <<'UDEV_EOF'
#!/bin/bash
# Auto-generated helper for udev MAC setting
IFACE="$1"
CPU_ID_HEX="$2"

if [ -z "$IFACE" ] || [ -z "$CPU_ID_HEX" ]; then
    exit 0
fi

MAC=$(python3 -c "
import sys, hashlib
cpu_id = bytes.fromhex(sys.argv[1])
if len(cpu_id) < 16:
    cpu_id = cpu_id.ljust(16, b'\x00')
seed = hashlib.sha256(cpu_id + sys.argv[2].encode('utf-8')).digest()
print('{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}'.format(0x02, seed[0], seed[1], seed[2], seed[3], seed[4]))
" "$CPU_ID_HEX" "$IFACE" 2>/dev/null)

if [ -n "$MAC" ]; then
    ip link set dev "$IFACE" down 2>/dev/null || true
    ip link set dev "$IFACE" address "$MAC" 2>/dev/null || true
    ip link set dev "$IFACE" up 2>/dev/null || true
fi
UDEV_EOF

chmod +x "$UDEV_HELPER"

cat > "$UDEV_RULE" <<EOF
# Auto-generated by dlcvcam-init.sh
# Sets per-interface MAC based on hardware CPU ID
ACTION=="add", SUBSYSTEM=="net", KERNEL=="eth*|enp*|ens*|usb*", RUN+="$UDEV_HELPER %k ${CPU_ID_HEX}"
EOF

echo "dlcvcam-init: udev rule generated at ${UDEV_RULE}"

# --- 6. Configure IPv4 link-local fallback for ethernet interfaces ---
# When the camera is directly connected to a host without a DHCP server,
# NetworkManager must fall back to an IPv4 link-local address (169.254.x.x)
# so that camos GVCP discovery can still respond and the host can find the
# device. Without this fallback the interface ends up with no IPv4 address
# and discovery fails.
#
# We use a "DHCP + static link-local" dual-stack setup:
# - address1 is a deterministic 169.254.x.x address derived from the MAC,
#   so the interface has an IPv4 address immediately after the cable is
#   plugged in, without waiting for DHCP.
# - DHCP is still active; if a DHCP server is present the interface will
#   also receive a routable address within dhcp-timeout seconds.
# - camos (smartcam_bs PR #119) prefers the non-link-local address when
#   both exist, so the host gets the usable DHCP address in normal networks.
generate_link_local_ip() {
    local mac="$1"
    python3 -c "
import sys, hashlib
mac = sys.argv[1]
mac_bytes = bytes.fromhex(mac.replace(':', ''))
h = hashlib.md5(mac_bytes).digest()
value = (h[0] << 8) | h[1]
if value in (0, 0xFFFF):
    value = 0x1234
print(f'169.254.{value >> 8}.{value & 0xFF}')
" "$mac" 2>/dev/null
}

configure_nm_lla_fallback() {
    local iface="$1"
    local conn_file="/etc/NetworkManager/system-connections/${iface}.nmconnection"

    mkdir -p "$(dirname "$conn_file")"

    local uuid
    uuid=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")

    local mac lla
    mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo "00:00:00:00:00:00")
    lla=$(generate_link_local_ip "$mac")

    cat > "$conn_file" <<EOF
[connection]
id=${iface}
uuid=${uuid}
type=ethernet
interface-name=${iface}
autoconnect=true
autoconnect-priority=100

[ethernet]

[ipv4]
method=auto
may-fail=true
dhcp-timeout=10
address1=${lla}/16

[ipv6]
addr-gen-mode=default
method=auto

[proxy]
EOF

    chmod 600 "$conn_file"
    echo "dlcvcam-init: Configured IPv4 link-local fallback for ${iface}: ${lla}/16 (DHCP still active)"
}

for iface in $IFACES; do
    IFACE_PATH="/sys/class/net/${iface}"
    if [ ! -d "$IFACE_PATH" ]; then
        continue
    fi
    configure_nm_lla_fallback "$iface"
done

# If NetworkManager is already running, reload so the new/updated connections
# take effect immediately; otherwise they will be picked up on next start.
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    nmcli connection reload 2>/dev/null || true
fi

# --- Enable LLA keepalive watchdog (direct-connect discoverability) ---
# NM's may-fail does not reliably retain the static link-local address in its
# DHCP fail-loop on direct-connect (no DHCP server), leaving the device without
# any IPv4 address and undiscoverable most of the time. The camos-lla-keepalive
# service re-adds the deterministic LLA at the kernel level every second,
# independent of NM/DHCP, so GVCP discovery always responds.
if [ -f /etc/systemd/system/camos-lla-keepalive.service ] && \
   [ -f /usr/local/bin/camos-lla-keepalive.sh ]; then
    systemctl enable camos-lla-keepalive.service 2>/dev/null || true
    if ! systemctl is-active --quiet camos-lla-keepalive.service 2>/dev/null; then
        systemctl start camos-lla-keepalive.service 2>/dev/null || true
    fi
fi
