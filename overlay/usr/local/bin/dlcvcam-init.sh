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
