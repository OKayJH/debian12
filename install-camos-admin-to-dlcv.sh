#!/bin/bash -e
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DLCV_PART_SRC="${DLCV_PART_SRC:-$HERE/dlcv_part_src}"
WHEEL="${CAMOS_ADMIN_WHEEL:?CAMOS_ADMIN_WHEEL must point to a camos_admin linux_aarch64 wheel}"
SITE_PACKAGES="$DLCV_PART_SRC/lib/python3.11/site-packages"

if [ ! -f "$WHEEL" ]; then
    echo "ERROR: CamOS Admin wheel not found: $WHEEL" >&2
    exit 1
fi

case "$(basename "$WHEEL")" in
    camos_admin-*-cp311-*-linux_aarch64.whl) ;;
    *)
        echo "ERROR: expected camos_admin cp311 linux_aarch64 wheel: $WHEEL" >&2
        exit 1
        ;;
esac

if [ ! -d "$SITE_PACKAGES" ]; then
    echo "ERROR: target site-packages missing: $SITE_PACKAGES" >&2
    exit 1
fi

echo "---------- Install CamOS Admin wheel -> $SITE_PACKAGES ----------"
sudo env CAMOS_ADMIN_WHEEL="$WHEEL" CAMOS_ADMIN_SITE_PACKAGES="$SITE_PACKAGES" python3 - <<'PY'
import os
import re
import shutil
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

wheel = Path(os.environ["CAMOS_ADMIN_WHEEL"]).resolve()
site = Path(os.environ["CAMOS_ADMIN_SITE_PACKAGES"]).resolve()
required = {
    "camos-admin",
    "static/app.asar",
    "dlcvcam_boot_try.py",
    "dlcvcam-boot-try-confirm.service",
    "install_dlcvcam_boot_try.sh",
    "10-dlcvcam-watchdog.conf",
    "dlcvcam_sync_boot_to_recovery.sh",
}

with zipfile.ZipFile(wheel) as zf:
    names = zf.namelist()
    metadata_names = [n for n in names if re.fullmatch(r"camos_admin-[^/]+\.dist-info/METADATA", n)]
    wheel_names = [n for n in names if re.fullmatch(r"camos_admin-[^/]+\.dist-info/WHEEL", n)]
    if len(metadata_names) != 1 or len(wheel_names) != 1:
        raise SystemExit("wheel has invalid camos_admin dist-info metadata")

    wheel_meta = zf.read(wheel_names[0]).decode("utf-8", "strict")
    if "Tag: cp311-none-linux_aarch64" not in wheel_meta:
        raise SystemExit("wheel is not tagged cp311-none-linux_aarch64")

    metadata = zf.read(metadata_names[0]).decode("utf-8", "strict")
    match = re.search(r"^Version:\s*(\S+)\s*$", metadata, re.MULTILINE)
    if not match:
        raise SystemExit("wheel version is missing")
    version = match.group(1)

    members = set(names)
    missing = sorted(
        name for name in required if not any(
            member == f"camos_admin/{name}" or member.endswith(f"/camos_admin/{name}")
            for member in members
        )
    )
    if missing:
        raise SystemExit("wheel is missing anti-brick assets: " + ", ".join(missing))

    shutil.rmtree(site / "camos_admin", ignore_errors=True)
    for stale in site.glob("camos_admin-*.dist-info"):
        shutil.rmtree(stale)

    for info in zf.infolist():
        path = PurePosixPath(info.filename)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe wheel member: {info.filename}")
        if not path.parts or path.parts[0] not in {"camos_admin", PurePosixPath(metadata_names[0]).parts[0]}:
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

package = site / "camos_admin"
for name in required:
    if not (package / name).is_file():
        raise SystemExit(f"installed asset missing: {package / name}")

binary = package / "camos-admin"
with binary.open("rb") as stream:
    elf = stream.read(20)
if len(elf) < 20 or elf[:4] != b"\x7fELF":
    raise SystemExit(f"installed Admin is not an ELF executable: {binary}")
byteorder = "little" if elf[5] == 1 else "big"
machine = int.from_bytes(elf[18:20], byteorder)
if machine != 183:  # EM_AARCH64
    raise SystemExit(f"installed Admin is not AArch64 (e_machine={machine}): {binary}")

for name in ("camos-admin", "dlcvcam_boot_try.py", "install_dlcvcam_boot_try.sh", "dlcvcam_sync_boot_to_recovery.sh"):
    path = package / name
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

print(f"installed camos_admin {version} from {wheel.name}")
PY
