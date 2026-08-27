#!/bin/bash
# DLCVCAM: manage recovery partition as factory/golden kernel warehouse.
#
# recovery = frozen known-good FIT (same format as boot.img)
# boot     = daily / experimental kernel (Admin update only touches boot)
#
# SSH-only manual ops. No systemd. No auto-upgrade hooks.
#
# Usage (on board, as root):
#   dlcvcam-sync-boot-to-recovery.sh status
#   DLCVCAM_I_UNDERSTAND=1 dlcvcam-sync-boot-to-recovery.sh sync-from-boot
#   DLCVCAM_I_UNDERSTAND=1 dlcvcam-sync-boot-to-recovery.sh restore-boot-from-recovery
#
# Safety:
#   - root only
#   - sync-from-boot requires boot FIT magic d00dfeed (refuse bad boot → recovery)
#   - restore requires recovery FIT magic
#   - destructive ops need DLCVCAM_I_UNDERSTAND=1 or interactive hostname confirm
#   - logs to syslog + /userdata/camos_kernel_backups/recovery-ops.log
#
set -euo pipefail

BOOT_PART="${DLCVCAM_BOOT_PART:-/dev/disk/by-partlabel/boot}"
RECOVERY_PART="${DLCVCAM_RECOVERY_PART:-/dev/disk/by-partlabel/recovery}"
BACKUP_DIR="${DLCVCAM_BACKUP_DIR:-/userdata/camos_kernel_backups}"
LOG_FILE="${DLCVCAM_RECOVERY_LOG:-${BACKUP_DIR}/recovery-ops.log}"
FIT_MAGIC_HEX="d00dfeed"
DD_BS="${DLCVCAM_DD_BS:-4M}"

PROG="$(basename "$0")"

log() {
	local msg="$*"
	printf '[%s] %s\n' "$(date '+%F %T')" "$msg"
	if mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
		printf '[%s] %s\n' "$(date '+%F %T')" "$msg" >>"$LOG_FILE" 2>/dev/null || true
	fi
	if command -v logger >/dev/null 2>&1; then
		logger -t dlcvcam-recovery -- "$msg" 2>/dev/null || true
	fi
}

die() {
	log "ERROR: $*"
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

need_root() {
	[[ "$(id -u)" -eq 0 ]] || die "必须 root 运行（当前 uid=$(id -u)）"
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

part_size() {
	blockdev --getsize64 "$1"
}

read_magic_hex() {
	# first 4 bytes as lowercase hex
	python3 - "$1" <<'PY'
import sys
path = sys.argv[1]
with open(path, "rb") as f:
    b = f.read(4)
print(b.hex() if len(b) == 4 else "")
PY
}

is_fit_magic() {
	local dev="$1"
	local magic
	magic="$(read_magic_hex "$dev")"
	[[ "$magic" == "$FIT_MAGIC_HEX" ]]
}

sha256_bytes() {
	# sha256 of first $2 bytes of device/file $1
	local path="$1"
	local nbytes="$2"
	python3 - "$path" "$nbytes" <<'PY'
import hashlib, sys
path, n = sys.argv[1], int(sys.argv[2])
h = hashlib.sha256()
left = n
with open(path, "rb") as f:
    while left > 0:
        chunk = f.read(min(1024 * 1024, left))
        if not chunk:
            break
        h.update(chunk)
        left -= len(chunk)
if left != 0:
    sys.stderr.write(f"short read: missing {left} bytes\n")
    sys.exit(2)
print(h.hexdigest())
PY
}

confirm_destructive() {
	local action="$1"
	if [[ "${DLCVCAM_I_UNDERSTAND:-}" == "1" ]]; then
		log "confirm: DLCVCAM_I_UNDERSTAND=1 for ${action}"
		return 0
	fi
	if [[ ! -t 0 ]]; then
		die "非交互环境请设置 DLCVCAM_I_UNDERSTAND=1 后再执行: ${action}"
	fi
	local host expect
	host="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"
	printf '即将执行: %s\n' "$action"
	printf '请输入主机名以确认 [%s]: ' "$host"
	read -r expect
	[[ "$expect" == "$host" ]] || die "主机名确认失败，已中止"
	log "confirm: hostname ok for ${action}"
}

usage() {
	cat <<EOF
用法: ${PROG} <command>

  status                      查看 boot/recovery 分区与当前内核
  sync-from-boot              将当前 boot 写入 recovery（更新出厂/金镜像）
  restore-boot-from-recovery  将 recovery 写回 boot（救援）

环境变量:
  DLCVCAM_I_UNDERSTAND=1   跳过交互确认（脚本/无人值守）
  DLCVCAM_BOOT_PART        默认 ${BOOT_PART}
  DLCVCAM_RECOVERY_PART    默认 ${RECOVERY_PART}
  DLCVCAM_BACKUP_DIR       默认 ${BACKUP_DIR}
  DLCVCAM_SKIP_RECOVERY_BAK=1  sync 前不备份旧 recovery 到 userdata

注意:
  - Admin/日常升级只应写 boot，不要自动跑 sync-from-boot
  - 仅在确认当前 boot 稳定健康后再更新 recovery
  - boot 非 FIT 时拒绝 sync-from-boot，防止双杀
EOF
}

cmd_status() {
	need_root
	need_cmd blockdev
	need_cmd python3

	echo "==== host ===="
	echo "hostname : $(hostname 2>/dev/null || true)"
	echo "uname    : $(uname -a)"
	if [[ -r /proc/cmdline ]]; then
		echo "cmdline  : $(cat /proc/cmdline)"
	fi
	echo

	local p dev sz magic sha_head
	for p in boot recovery; do
		if [[ "$p" == boot ]]; then
			dev="$BOOT_PART"
		else
			dev="$RECOVERY_PART"
		fi
		echo "==== ${p} (${dev}) ===="
		if [[ ! -b "$dev" && ! -e "$dev" ]]; then
			echo "MISSING"
			echo
			continue
		fi
		sz="$(part_size "$dev")"
		magic="$(read_magic_hex "$dev")"
		# first 1MiB fingerprint (fast); full compare is separate
		sha_head="$(sha256_bytes "$dev" 1048576 2>/dev/null || echo n/a)"
		echo "size     : ${sz} bytes"
		echo "magic    : ${magic} $([ "$magic" = "$FIT_MAGIC_HEX" ] && echo '(FIT OK)' || echo '(NOT FIT)')"
		echo "sha256@1M: ${sha_head}"
		if command -v hexdump >/dev/null 2>&1; then
			hexdump -C "$dev" -n 32 | sed 's/^/  /'
		fi
		echo
	done

	if [[ -b "$BOOT_PART" && -b "$RECOVERY_PART" ]]; then
		local bs rs
		bs="$(part_size "$BOOT_PART")"
		rs="$(part_size "$RECOVERY_PART")"
		local cmp_n="$bs"
		if [[ "$rs" -lt "$cmp_n" ]]; then
			cmp_n="$rs"
		fi
		# Compare min(boot,recovery) full size can be 64M — ok on device
		local sb sr
		sb="$(sha256_bytes "$BOOT_PART" "$cmp_n")"
		sr="$(sha256_bytes "$RECOVERY_PART" "$cmp_n")"
		echo "==== compare first ${cmp_n} bytes ===="
		echo "boot     : ${sb}"
		echo "recovery : ${sr}"
		if [[ "$sb" == "$sr" ]]; then
			echo "match    : YES (boot and recovery payload identical for compared length)"
		else
			echo "match    : NO (recovery is independent golden image — expected if boot was upgraded)"
		fi
	fi

	if [[ -f "$LOG_FILE" ]]; then
		echo
		echo "==== last log lines (${LOG_FILE}) ===="
		tail -n 5 "$LOG_FILE" 2>/dev/null || true
	fi
}

dd_copy() {
	local ifdev="$1"
	local ofdev="$2"
	local nbytes="$3"
	# Copy exactly nbytes using dd with fullblock; pad not required when nbytes == boot size
	# Use bytes count via python for exactness when not multiple of bs — fallback dd+count.
	python3 - "$ifdev" "$ofdev" "$nbytes" <<'PY'
import os, sys
src, dst, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
bs = 4 * 1024 * 1024
left = n
with open(src, "rb") as fi, open(dst, "r+b", buffering=0) as fo:
    while left > 0:
        chunk = fi.read(min(bs, left))
        if not chunk:
            raise SystemExit(f"short read from {src}, left={left}")
        fo.write(chunk)
        left -= len(chunk)
    fo.flush()
    os.fsync(fo.fileno())
print(f"wrote {n} bytes {src} -> {dst}")
PY
	sync
}

cmd_sync_from_boot() {
	need_root
	need_cmd blockdev
	need_cmd python3
	need_cmd dd

	[[ -b "$BOOT_PART" || -e "$BOOT_PART" ]] || die "boot 分区不存在: $BOOT_PART"
	[[ -b "$RECOVERY_PART" || -e "$RECOVERY_PART" ]] || die "recovery 分区不存在: $RECOVERY_PART"

	is_fit_magic "$BOOT_PART" || die "boot 不是 FIT magic (${FIT_MAGIC_HEX})，拒绝写入 recovery（防止双杀）"

	local boot_sz rec_sz
	boot_sz="$(part_size "$BOOT_PART")"
	rec_sz="$(part_size "$RECOVERY_PART")"
	[[ "$boot_sz" -le "$rec_sz" ]] || die "boot 分区 (${boot_sz}) 大于 recovery (${rec_sz})，无法整分区同步"

	confirm_destructive "sync-from-boot: ${BOOT_PART} -> ${RECOVERY_PART} (${boot_sz} bytes)"

	mkdir -p "$BACKUP_DIR"

	if [[ "${DLCVCAM_SKIP_RECOVERY_BAK:-}" != "1" ]]; then
		local bak="${BACKUP_DIR}/recovery-before-$(date +%Y%m%d-%H%M%S).img"
		log "backup old recovery -> ${bak} (${boot_sz} bytes prefix or full boot-sized)"
		# backup same length we will overwrite (boot_sz), enough to restore golden
		python3 - "$RECOVERY_PART" "$bak" "$boot_sz" <<'PY'
import os, sys
src, dst, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
bs = 4 * 1024 * 1024
left = n
with open(src, "rb") as fi, open(dst, "wb") as fo:
    while left > 0:
        chunk = fi.read(min(bs, left))
        if not chunk:
            raise SystemExit("short read backup")
        fo.write(chunk)
        left -= len(chunk)
    fo.flush()
    os.fsync(fo.fileno())
print(dst)
PY
		log "backup done: ${bak}"
	else
		log "skip recovery backup (DLCVCAM_SKIP_RECOVERY_BAK=1)"
	fi

	local sha_src sha_dst
	sha_src="$(sha256_bytes "$BOOT_PART" "$boot_sz")"
	log "sync start sha256(boot[:${boot_sz}])=${sha_src}"

	dd_copy "$BOOT_PART" "$RECOVERY_PART" "$boot_sz"

	# drop caches best-effort
	echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true
	sha_dst="$(sha256_bytes "$RECOVERY_PART" "$boot_sz")"
	[[ "$sha_dst" == "$sha_src" ]] || die "回读校验失败: recovery=${sha_dst} boot=${sha_src}"
	is_fit_magic "$RECOVERY_PART" || die "写入后 recovery 非 FIT magic"

	log "sync-from-boot OK sha256=${sha_dst}"
	echo "OK: recovery 已更新为当前 boot 内容"
	echo "sha256(${boot_sz} bytes)=${sha_dst}"
	echo "uname: $(uname -a)"
}

cmd_restore_boot_from_recovery() {
	need_root
	need_cmd blockdev
	need_cmd python3

	[[ -b "$BOOT_PART" || -e "$BOOT_PART" ]] || die "boot 分区不存在: $BOOT_PART"
	[[ -b "$RECOVERY_PART" || -e "$RECOVERY_PART" ]] || die "recovery 分区不存在: $RECOVERY_PART"

	is_fit_magic "$RECOVERY_PART" || die "recovery 不是 FIT magic，拒绝写回 boot"

	local boot_sz rec_sz copy_sz
	boot_sz="$(part_size "$BOOT_PART")"
	rec_sz="$(part_size "$RECOVERY_PART")"
	# Write min(boot,recovery) — normally copy boot_sz from recovery head
	copy_sz="$boot_sz"
	if [[ "$rec_sz" -lt "$copy_sz" ]]; then
		die "recovery (${rec_sz}) 小于 boot (${boot_sz})，无法安全写回"
	fi

	confirm_destructive "restore-boot-from-recovery: ${RECOVERY_PART} -> ${BOOT_PART} (${copy_sz} bytes)"

	mkdir -p "$BACKUP_DIR"
	local bak="${BACKUP_DIR}/boot-before-restore-$(date +%Y%m%d-%H%M%S).img"
	log "backup current boot -> ${bak}"
	python3 - "$BOOT_PART" "$bak" "$boot_sz" <<'PY'
import os, sys
src, dst, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
bs = 4 * 1024 * 1024
left = n
with open(src, "rb") as fi, open(dst, "wb") as fo:
    while left > 0:
        chunk = fi.read(min(bs, left))
        if not chunk:
            raise SystemExit("short read")
        fo.write(chunk)
        left -= len(chunk)
    fo.flush()
    os.fsync(fo.fileno())
PY

	local sha_src sha_dst
	sha_src="$(sha256_bytes "$RECOVERY_PART" "$copy_sz")"
	log "restore start sha256(recovery[:${copy_sz}])=${sha_src}"

	dd_copy "$RECOVERY_PART" "$BOOT_PART" "$copy_sz"

	echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true
	sha_dst="$(sha256_bytes "$BOOT_PART" "$copy_sz")"
	[[ "$sha_dst" == "$sha_src" ]] || die "回读校验失败: boot=${sha_dst} recovery=${sha_src}"
	is_fit_magic "$BOOT_PART" || die "写回后 boot 非 FIT magic"

	log "restore-boot-from-recovery OK sha256=${sha_dst}"
	echo "OK: boot 已从 recovery 恢复"
	echo "sha256(${copy_sz} bytes)=${sha_dst}"
	echo "请执行: reboot"
}

main() {
	local cmd="${1:-}"
	case "$cmd" in
	status) cmd_status ;;
	sync-from-boot) cmd_sync_from_boot ;;
	restore-boot-from-recovery) cmd_restore_boot_from_recovery ;;
	-h | --help | help)
		usage
		exit 0
		;;
	"")
		usage
		exit 1
		;;
	*)
		usage
		die "未知命令: $cmd"
		;;
	esac
}

main "$@"
