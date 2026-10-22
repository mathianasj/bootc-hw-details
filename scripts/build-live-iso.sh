#!/usr/bin/env bash
# Build a live (dmsquash) ISO from a bootc container that ships the
# container-native ISO contract (iso.yaml + live initramfs + EFI/GRUB).
#
# Avoids osbuild/image-builder, which fails on some RHEL hosts with
# "layer not known" inside org.osbuild.container-deploy.
#
# Usage:
#   sudo ./scripts/build-live-iso.sh \
#     --image localhost/bootc-hw-gather:latest \
#     --output ./output/iso/bootc-hw-gather.iso
#
# Or with an already-mounted rootfs (e.g. podman --mount type=image):
#   ./scripts/build-live-iso.sh --rootfs /rootfs --output /output/bootc-hw-gather.iso

set -euo pipefail

IMAGE=""
ROOTFS=""
OUTPUT=""
WORKDIR=""
PODMAN="${PODMAN:-podman}"

usage() {
  sed -n '2,16p' "$0" | sed 's/^# //;s/^#//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --rootfs) ROOTFS="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$OUTPUT" ]] || { echo "--output is required" >&2; exit 1; }
[[ -n "$IMAGE" || -n "$ROOTFS" ]] || { echo "--image or --rootfs is required" >&2; exit 1; }

if [[ -z "$WORKDIR" ]]; then
  WORKDIR="$(mktemp -d /var/tmp/bootc-live-iso.XXXXXX)"
  OWN_WORKDIR=1
else
  OWN_WORKDIR=0
  mkdir -p "$WORKDIR"
fi

CID=""
cleanup() {
  if [[ -n "$CID" ]]; then
    "$PODMAN" umount "$CID" >/dev/null 2>&1 || true
    "$PODMAN" rm "$CID" >/dev/null 2>&1 || true
  fi
  if [[ "$OWN_WORKDIR" -eq 1 ]]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

if [[ -z "$ROOTFS" ]]; then
  echo "==> mounting $IMAGE"
  CID="$("$PODMAN" create --name "bootc-live-iso-$$" "$IMAGE")"
  ROOTFS="$("$PODMAN" mount "$CID")"
fi

ISO_YAML=""
for candidate in \
  "$ROOTFS/usr/lib/bootc-image-builder/iso.yaml" \
  "$ROOTFS/usr/lib/image-builder/bootc/iso.yaml"
do
  if [[ -f "$candidate" ]]; then
    ISO_YAML="$candidate"
    break
  fi
done
[[ -n "$ISO_YAML" ]] || { echo "iso.yaml not found under $ROOTFS" >&2; exit 1; }

KDIR="$(ls -1d "$ROOTFS"/usr/lib/modules/*/ 2>/dev/null | head -n1 || true)"
[[ -n "$KDIR" && -f "${KDIR}vmlinuz" && -f "${KDIR}initramfs.img" ]] || {
  echo "kernel/initramfs.img missing under $ROOTFS/usr/lib/modules" >&2
  exit 1
}

mapfile -t ISO_META < <(python3 - "$ISO_YAML" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
label = None
default = 0
timeout = 5
entries = []
current = None

for raw in path.read_text().splitlines():
    line = raw.rstrip()
    if not line or line.lstrip().startswith("#"):
        continue
    indent = len(line) - len(line.lstrip(" "))
    stripped = line.strip()
    if indent == 0 and stripped.startswith("label:"):
        label = stripped.split(":", 1)[1].strip().strip("\"'")
    elif indent == 0 and stripped.startswith("grub2:"):
        continue
    elif stripped.startswith("default:"):
        default = int(stripped.split(":", 1)[1].strip())
    elif stripped.startswith("timeout:"):
        timeout = int(stripped.split(":", 1)[1].strip())
    elif stripped.startswith("- name:"):
        if current:
            entries.append(current)
        current = {"name": stripped.split(":", 1)[1].strip().strip("\"'"), "linux": "", "initrd": ""}
    elif current is not None and stripped.startswith("linux:"):
        current["linux"] = stripped.split(":", 1)[1].strip().strip("\"'")
    elif current is not None and stripped.startswith("initrd:"):
        current["initrd"] = stripped.split(":", 1)[1].strip().strip("\"'")

if current:
    entries.append(current)

if not label:
    raise SystemExit("iso.yaml missing label")
if not entries:
    raise SystemExit("iso.yaml missing grub2.entries")

print(label)
print(default)
print(timeout)
for ent in entries:
    # linux field is "/images/pxeboot/vmlinuz <kargs...>"
    parts = ent["linux"].split(None, 1)
    kargs = parts[1] if len(parts) > 1 else ""
    print("\t".join([ent["name"], kargs, ent["initrd"]]))
PY
)

LABEL="${ISO_META[0]}"
GRUB_DEFAULT="${ISO_META[1]}"
GRUB_TIMEOUT="${ISO_META[2]}"
ENTRIES=("${ISO_META[@]:3}")

ISO_ROOT="$WORKDIR/iso-root"
rm -rf "$ISO_ROOT"
mkdir -p \
  "$ISO_ROOT/images/pxeboot" \
  "$ISO_ROOT/LiveOS" \
  "$ISO_ROOT/boot/grub" \
  "$ISO_ROOT/EFI/BOOT"

echo "==> copying kernel and initramfs"
cp -a "${KDIR}vmlinuz" "$ISO_ROOT/images/pxeboot/vmlinuz"
cp -a "${KDIR}initramfs.img" "$ISO_ROOT/images/pxeboot/initrd.img"

echo "==> copying EFI bootloaders"
if [[ -d "$ROOTFS/boot/efi/EFI" ]]; then
  cp -a "$ROOTFS/boot/efi/EFI/." "$ISO_ROOT/EFI/"
fi
# Removable-media layout expected by many firmwares.
if [[ -f "$ISO_ROOT/EFI/redhat/shimx64.efi" ]]; then
  cp -a "$ISO_ROOT/EFI/redhat/shimx64.efi" "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI"
elif [[ -f "$ISO_ROOT/EFI/centos/shimx64.efi" ]]; then
  cp -a "$ISO_ROOT/EFI/centos/shimx64.efi" "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI"
elif [[ -f "$ISO_ROOT/EFI/fedora/shimx64.efi" ]]; then
  cp -a "$ISO_ROOT/EFI/fedora/shimx64.efi" "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI"
elif [[ -f "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI" ]]; then
  :
else
  # Fall back to any shimx64.efi we can find.
  shim="$(find "$ISO_ROOT/EFI" -name 'shimx64.efi' | head -n1 || true)"
  [[ -n "$shim" ]] || { echo "shimx64.efi not found under EFI" >&2; exit 1; }
  cp -a "$shim" "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI"
fi

echo "==> writing grub.cfg"
GRUB_CFG="$ISO_ROOT/boot/grub/grub.cfg"
{
  echo "set default=${GRUB_DEFAULT}"
  echo "set timeout=${GRUB_TIMEOUT}"
  echo
  for row in "${ENTRIES[@]}"; do
    IFS=$'\t' read -r name kargs initrd <<<"$row"
    echo "menuentry '${name}' {"
    echo "  linux /images/pxeboot/vmlinuz ${kargs}"
    echo "  initrd ${initrd}"
    echo "}"
    echo
  done
} >"$GRUB_CFG"
# UEFI grub looks under EFI/BOOT and vendor dirs.
mkdir -p "$ISO_ROOT/EFI/BOOT"
cp -a "$GRUB_CFG" "$ISO_ROOT/EFI/BOOT/grub.cfg"
for vendor_dir in "$ISO_ROOT"/EFI/*/; do
  base="$(basename "$vendor_dir")"
  [[ "$base" == "BOOT" ]] && continue
  cp -a "$GRUB_CFG" "${vendor_dir}grub.cfg"
done

echo "==> creating squashfs (this takes a while)"
mksquashfs "$ROOTFS" "$ISO_ROOT/LiveOS/squashfs.img" \
  -noappend -comp xz -Xbcj x86 -b 1M -processors "$(nproc)" \
  -e boot/efi proc sys dev run tmp var/tmp \
  -e root/.cache var/cache var/lib/containers

echo "==> building EFI boot image"
EFI_IMG="$WORKDIR/efiboot.img"
ESP_MNT="$WORKDIR/esp"
rm -f "$EFI_IMG"
rm -rf "$ESP_MNT"
mkdir -p "$ESP_MNT"
truncate -s 64M "$EFI_IMG"
mkfs.vfat -n ESP "$EFI_IMG" >/dev/null
mount -o loop "$EFI_IMG" "$ESP_MNT"
cp -a "$ISO_ROOT/EFI" "$ESP_MNT/"
umount "$ESP_MNT"
cp -a "$EFI_IMG" "$ISO_ROOT/EFI/BOOT/efiboot.img"

echo "==> building hybrid ISO"
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"

BIOS_IMG=""
if [[ -d /usr/lib/grub/i386-pc || -d "$ROOTFS/usr/lib/grub/i386-pc" ]]; then
  GRUB_PC_MODDIR="/usr/lib/grub/i386-pc"
  [[ -d "$GRUB_PC_MODDIR" ]] || GRUB_PC_MODDIR="$ROOTFS/usr/lib/grub/i386-pc"
  BIOS_CORE="$WORKDIR/core.img"
  if grub2-mkimage -O i386-pc -d "$GRUB_PC_MODDIR" -o "$BIOS_CORE" -p /boot/grub \
    boot linux linux16 normal configfile part_gpt part_msdos fat iso9660 \
    biosdisk search search_fs_file search_fs_uuid search_label echo ls \
    test true help cat all_video
  then
    if [[ -f "$GRUB_PC_MODDIR/cdboot.img" ]]; then
      BIOS_IMG="$ISO_ROOT/boot/grub/eltorito.img"
      cat "$GRUB_PC_MODDIR/cdboot.img" "$BIOS_CORE" >"$BIOS_IMG"
    fi
  fi
fi

XORRISO_ARGS=(
  -as mkisofs
  -R -r -J -joliet-long
  -V "$LABEL"
  -o "$OUTPUT"
)

if [[ -n "$BIOS_IMG" ]]; then
  XORRISO_ARGS+=(
    -c boot.catalog
    -b boot/grub/eltorito.img
    -no-emul-boot
    -boot-load-size 4
    -boot-info-table
    -eltorito-alt-boot
  )
fi

XORRISO_ARGS+=(
  -e EFI/BOOT/efiboot.img
  -no-emul-boot
  -isohybrid-gpt-basdat
)

if [[ -f /usr/lib/grub/i386-pc/boot_hybrid.img ]]; then
  XORRISO_ARGS+=(--grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img)
fi

xorriso "${XORRISO_ARGS[@]}" "$ISO_ROOT"

if command -v implantisomd5 >/dev/null 2>&1; then
  implantisomd5 "$OUTPUT"
fi

echo "==> wrote $OUTPUT ($(du -h "$OUTPUT" | awk '{print $1}'))"
