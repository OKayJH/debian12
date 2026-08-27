#!/bin/bash -e
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DLCV_PART_SRC="${DLCV_PART_SRC:-$HERE/dlcv_part_src}"
CORE_WHEEL="${CAMOS_CORE_WHEEL:?CAMOS_CORE_WHEEL must point to a camos linux_aarch64 wheel}"
ADMIN_WHEEL="${CAMOS_ADMIN_WHEEL:?CAMOS_ADMIN_WHEEL must point to a camos_admin linux_aarch64 wheel}"
SITE_PACKAGES="$DLCV_PART_SRC/lib/python3.11/site-packages"

for wheel in "$CORE_WHEEL" "$ADMIN_WHEEL"; do
    [ -f "$wheel" ] || { echo "ERROR: wheel not found: $wheel" >&2; exit 1; }
done
[ -d "$SITE_PACKAGES" ] || { echo "ERROR: target site-packages missing: $SITE_PACKAGES" >&2; exit 1; }

sudo env \
    CAMOS_CORE_WHEEL="$CORE_WHEEL" \
    CAMOS_ADMIN_WHEEL="$ADMIN_WHEEL" \
    CAMOS_SITE_PACKAGES="$SITE_PACKAGES" \
    python3 - <<'PY'
import os
import re
import shutil
import stat
import zipfile
from pathlib import Path, PurePosixPath

site = Path(os.environ["CAMOS_SITE_PACKAGES"]).resolve()
targets = [
    {
        "wheel": Path(os.environ["CAMOS_CORE_WHEEL"]).resolve(),
        "dist": "camos",
        "package": "camos",
        "binary": "camos",
        "required": {
            "camos",
            "static/app.asar",
            "runtime_settings.json",
            "runtime_settings_dlcvcam.json",
        },
    },
    {
        "wheel": Path(os.environ["CAMOS_ADMIN_WHEEL"]).resolve(),
        "dist": "camos_admin",
        "package": "camos_admin",
        "binary": "camos-admin",
        "required": {
            "camos-admin",
            "static/app.asar",
            "dlcvcam_boot_try.py",
            "dlcvcam-boot-try-confirm.service",
            "install_dlcvcam_boot_try.sh",
            "10-dlcvcam-watchdog.conf",
            "dlcvcam_sync_boot_to_recovery.sh",
        },
    },
]


def elf_machine(path: Path) -> int:
    with path.open("rb") as stream:
        elf = stream.read(20)
    if len(elf) < 20 or elf[:4] != b"\x7fELF":
        raise SystemExit(f"not an ELF executable: {path}")
    byteorder = "little" if elf[5] == 1 else "big"
    return int.from_bytes(elf[18:20], byteorder)


for target in targets:
    wheel = target["wheel"]
    dist = target["dist"]
    package_name = target["package"]
    with zipfile.ZipFile(wheel) as zf:
        names = zf.namelist()
        metadata_names = [
            n for n in names
            if re.fullmatch(rf"{re.escape(dist)}-[^/]+\.dist-info/METADATA", n)
        ]
        wheel_names = [
            n for n in names
            if re.fullmatch(rf"{re.escape(dist)}-[^/]+\.dist-info/WHEEL", n)
        ]
        if len(metadata_names) != 1 or len(wheel_names) != 1:
            raise SystemExit(f"invalid {dist} dist-info metadata in {wheel}")
        wheel_meta = zf.read(wheel_names[0]).decode("utf-8", "strict")
        if "Tag: cp311-none-linux_aarch64" not in wheel_meta:
            raise SystemExit(f"wheel is not cp311-none-linux_aarch64: {wheel}")
        metadata = zf.read(metadata_names[0]).decode("utf-8", "strict")
        match = re.search(r"^Version:\s*(\S+)\s*$", metadata, re.MULTILINE)
        if not match:
            raise SystemExit(f"wheel version missing: {wheel}")
        version = match.group(1)

        members = set(names)
        missing = sorted(
            name for name in target["required"]
            if f"{package_name}/{name}" not in members
        )
        if missing:
            raise SystemExit(f"{wheel.name} missing assets: {', '.join(missing)}")
        asar_info = zf.getinfo(f"{package_name}/static/app.asar")
        if asar_info.file_size == 0:
            raise SystemExit(f"{wheel.name} has empty app.asar")

        shutil.rmtree(site / package_name, ignore_errors=True)
        for stale in site.glob(f"{dist}-*.dist-info"):
            shutil.rmtree(stale)
        dist_info = PurePosixPath(metadata_names[0]).parts[0]
        for info in zf.infolist():
            path = PurePosixPath(info.filename)
            if path.is_absolute() or ".." in path.parts:
                raise SystemExit(f"unsafe wheel member: {info.filename}")
            if not path.parts or path.parts[0] not in {package_name, dist_info}:
                continue
            dst = site.joinpath(*path.parts)
            if info.is_dir():
                dst.mkdir(parents=True, exist_ok=True)
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, dst.open("wb") as out:
                shutil.copyfileobj(src, out)
            mode = (info.external_attr >> 16) & 0o777
            dst.chmod(mode or 0o644)

    package = site / package_name
    for name in target["required"]:
        path = package / name
        if not path.is_file() or path.stat().st_size == 0:
            raise SystemExit(f"installed asset missing or empty: {path}")
    binary = package / target["binary"]
    machine = elf_machine(binary)
    if machine != 183:
        raise SystemExit(f"installed executable is not AArch64 (e_machine={machine}): {binary}")
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"installed {dist} {version} from {wheel.name}")
PY
