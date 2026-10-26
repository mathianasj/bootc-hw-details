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
SQ_MNT=""
cleanup() {
  if [[ -n "$SQ_MNT" ]] && mountpoint -q "$SQ_MNT" 2>/dev/null; then
    umount "$SQ_MNT" >/dev/null 2>&1 || true
  fi
  # Overlay upper/work are root-owned; always remove so later ansible.builtin.find
  # is not blocked by Permission denied on sq-work/work.
  if [[ -n "${WORKDIR:-}" ]]; then
    rm -rf "${WORKDIR}/sq-upper" "${WORKDIR}/sq-work" "${WORKDIR}/sq-mnt" "${WORKDIR}/sq-check" 2>/dev/null || true
  fi
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
mkdir -p "$ISO_ROOT/EFI/BOOT" "$ISO_ROOT/EFI/redhat"
if [[ -d "$ROOTFS/boot/efi/EFI" ]]; then
  cp -a "$ROOTFS/boot/efi/EFI/." "$ISO_ROOT/EFI/"
fi
# Also pull from /usr/lib/efi trees if /boot/efi was incomplete.
for efi_dir in "$ROOTFS"/usr/lib/efi/*/*/EFI "$ROOTFS"/usr/lib/efi/*/EFI; do
  [[ -d "$efi_dir" ]] || continue
  cp -a "$efi_dir"/. "$ISO_ROOT/EFI/" 2>/dev/null || true
done

# Removable-media BOOTX64.EFI: use what's already staged, else copy shim/grub.
copy_if_different() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || return 1
  mkdir -p "$(dirname "$dst")"
  if [[ -e "$dst" ]] && [[ "$(realpath "$src")" == "$(realpath "$dst")" ]]; then
    return 0
  fi
  cp -a "$src" "$dst"
}

if [[ ! -f "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI" ]]; then
  bootx64=""
  for candidate in \
    "$ISO_ROOT/EFI/redhat/shimx64.efi" \
    "$ISO_ROOT/EFI/centos/shimx64.efi" \
    "$ISO_ROOT/EFI/fedora/shimx64.efi" \
    "$ROOTFS/boot/efi/EFI/BOOT/BOOTX64.EFI" \
    "$ROOTFS/boot/efi/EFI/redhat/shimx64.efi" \
    "$ROOTFS/usr/share/shim/shimx64.efi" \
    "$ROOTFS/usr/lib/shim/shimx64.efi"
  do
    if [[ -f "$candidate" ]]; then
      bootx64="$candidate"
      break
    fi
  done
  if [[ -z "$bootx64" ]]; then
    bootx64="$(find "$ISO_ROOT/EFI" "$ROOTFS/boot/efi" "$ROOTFS/usr/lib/efi" "$ROOTFS/usr/share" \
      \( -iname 'shimx64.efi' -o -iname 'BOOTX64.EFI' \) 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$bootx64" ]]; then
    # Last resort: unsigned grub EFI as the removable loader (no Secure Boot).
    bootx64="$(find "$ISO_ROOT/EFI" "$ROOTFS" -iname 'grubx64.efi' 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$bootx64" || ! -f "$bootx64" ]]; then
    echo "EFI loader not found (shimx64.efi / BOOTX64.EFI / grubx64.efi)." >&2
    echo "Searched under $ROOTFS/boot/efi and $ROOTFS/usr/lib/efi:" >&2
    find "$ROOTFS/boot/efi" "$ROOTFS/usr/lib/efi" "$ROOTFS/usr/share/shim" \
      -iname '*.efi' 2>/dev/null | head -n50 >&2 || true
    exit 1
  fi
  copy_if_different "$bootx64" "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI"
fi
# Keep a vendor shim copy when missing.
if [[ ! -f "$ISO_ROOT/EFI/redhat/shimx64.efi" && -f "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI" ]]; then
  copy_if_different "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI" "$ISO_ROOT/EFI/redhat/shimx64.efi"
fi
# Ensure grubx64.efi exists next to shim when available.
if [[ ! -f "$ISO_ROOT/EFI/redhat/grubx64.efi" ]]; then
  grubefi="$(find "$ISO_ROOT/EFI" "$ROOTFS/boot/efi" "$ROOTFS/usr/lib/grub" \
    -iname 'grubx64.efi' 2>/dev/null | head -n1 || true)"
  if [[ -n "$grubefi" ]]; then
    copy_if_different "$grubefi" "$ISO_ROOT/EFI/redhat/grubx64.efi"
    copy_if_different "$grubefi" "$ISO_ROOT/EFI/BOOT/grubx64.efi"
  fi
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
# dmsquash-live (rd.live.image + overlayfs) accepts a squashfs as the root only
# if /proc exists as a directory inside it. Excluding bare "proc" removes the
# dir and boot dies with:
#   Failed to find a root filesystem in .../LiveOS/squashfs.img
# Also: if LiveOS/ exists inside the squashfs without rootfs.img, dracut takes
# that branch and never falls through to the /proc check — exclude it.
#
# Writable overlay (ROOTFS from podman mount is RO) + mksquashfs -p to force
# empty mountpoint dirs, then verify before writing the ISO.
SQ_UPPER="$WORKDIR/sq-upper"
SQ_WORK="$WORKDIR/sq-work"
SQ_MNT="$WORKDIR/sq-mnt"
SQ_CHECK="$WORKDIR/sq-check"
rm -rf "$SQ_UPPER" "$SQ_WORK" "$SQ_MNT" "$SQ_CHECK"
mkdir -p "$SQ_UPPER" "$SQ_WORK" "$SQ_MNT"
mount -t overlay overlay \
  -o "lowerdir=${ROOTFS},upperdir=${SQ_UPPER},workdir=${SQ_WORK}" \
  "$SQ_MNT"
# Clear any accidental nested live layout from the container tree.
rm -rf "$SQ_MNT/LiveOS"
mkdir -p "$SQ_MNT"/{proc,sys,dev,run,tmp,var/tmp}
# -p forces empty dirs into the image even if excludes/mountpoints confuse mksquashfs.
mksquashfs "$SQ_MNT" "$ISO_ROOT/LiveOS/squashfs.img" \
  -noappend -comp xz -Xbcj x86 -b 1M -processors "$(nproc)" \
  -wildcards \
  -e 'LiveOS' \
  -e 'LiveOS/*' \
  -e 'boot/efi' \
  -e 'boot/efi/*' \
  -e 'proc/*' \
  -e 'sys/*' \
  -e 'dev/*' \
  -e 'run/*' \
  -e 'tmp/*' \
  -e 'var/tmp/*' \
  -e 'root/.cache' \
  -e 'root/.cache/*' \
  -e 'var/cache' \
  -e 'var/cache/*' \
  -e 'var/lib/containers' \
  -e 'var/lib/containers/*' \
  -p 'proc d 755 0 0' \
  -p 'sys d 755 0 0' \
  -p 'dev d 755 0 0' \
  -p 'run d 755 0 0' \
  -p 'tmp d 755 0 0'
umount "$SQ_MNT"
SQ_MNT=""

echo "==> verifying squashfs is a dmsquash-compatible root (/proc present)"
mkdir -p "$SQ_CHECK"
mount -o loop,ro "$ISO_ROOT/LiveOS/squashfs.img" "$SQ_CHECK"
if [[ -d "$SQ_CHECK/LiveOS" && ! -f "$SQ_CHECK/LiveOS/rootfs.img" && ! -f "$SQ_CHECK/LiveOS/ext3fs.img" ]]; then
  echo "ERROR: squashfs contains LiveOS/ without rootfs.img (dmsquash will fail)." >&2
  ls -la "$SQ_CHECK/LiveOS" >&2 || true
  umount "$SQ_CHECK" || true
  exit 1
fi
if [[ ! -d "$SQ_CHECK/proc" ]]; then
  echo "ERROR: squashfs missing /proc — dmsquash-live cannot use it as root." >&2
  echo "Top of squashfs:" >&2
  ls -la "$SQ_CHECK" >&2 || true
  umount "$SQ_CHECK" || true
  exit 1
fi
umount "$SQ_CHECK"
echo "    ok: /proc present in LiveOS/squashfs.img"

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
