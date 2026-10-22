# RHEL 9 image mode (bootc) — live ISO that boots, runs hw-gather, does not install
FROM registry.redhat.io/rhel9/rhel-bootc:latest

RUN <<EOF
set -euxo pipefail

# The base image points subscription-manager at the container host.
# Drop that so the build can use entitlements + repos mounted from the subscribed host.
rm -f /etc/rhsm-host

# Host must bind-mount /etc/yum.repos.d, /etc/pki/entitlement, /etc/rhsm,
# and /etc/pki/consumer. Prefer the manual CDN repos when present; otherwise
# subscription-manager CDN repo ids. sslverify=0 avoids the entitlement-CA
# error this host's dnf hits even when sslcacert is set.
if [[ -f /etc/yum.repos.d/rhel9-cdn-manual.repo ]]; then
  mapfile -t DNF_CDN < <(printf '%s\n' \
    --setopt=sslverify=0 \
    --setopt=sslverifystatus=0 \
    --disablerepo='*' \
    --enablerepo=rhel9-baseos-manual \
    --enablerepo=rhel9-appstream-manual)
else
  mapfile -t DNF_CDN < <(printf '%s\n' \
    --setopt=sslverify=0 \
    --setopt=sslverifystatus=0 \
    --disablerepo='*' \
    --enablerepo=rhel-9-for-x86_64-baseos-rpms \
    --enablerepo=rhel-9-for-x86_64-appstream-rpms)
fi
dnf -y "${DNF_CDN[@]}" repolist
# Live ISO contract tools (image-builder bootc-generic-iso):
# mksquashfs, xorriso, implantisomd5, grub2-mkimage, python, podman.
# rhel-bootc already ships podman + python3.
dnf -y "${DNF_CDN[@]}" install \
    lldpd \
    ethtool \
    pciutils \
    usbutils \
    smartmontools \
    iproute \
    NetworkManager \
    openssh-server \
    dracut-live \
    squashfs-tools \
    xorriso \
    isomd5sum \
    grub2-tools \
    grub2-efi-x64-cdboot \
    grub2-pc-modules \
    grub2-common

dnf clean all
EOF

COPY usr/ /usr/

RUN <<EOF
set -euxo pipefail

chmod 0755 /usr/libexec/hw-gather/gather.sh

# Newer image-builder looks here; titanoboa / older contract use bootc-image-builder.
mkdir -p /usr/lib/image-builder/bootc
ln -sfn /usr/lib/bootc-image-builder/iso.yaml /usr/lib/image-builder/bootc/iso.yaml

# Squashfs live root is incompatible with composefs.
cat > /usr/lib/ostree/prepare-root.conf <<'CONF'
[composefs]
enabled = no
[sysroot]
readonly = true
CONF

# Initramfs must understand LiveOS/squashfs.img on the ISO.
cat > /usr/lib/dracut/dracut.conf.d/40-live.conf <<'CONF'
compress="xz"
hostonly="no"
early_microcode="no"
add_dracutmodules+=" dmsquash-live dmsquash-live-autooverlay "
CONF

# EFI layout expected by the container-native ISO contract.
mkdir -p /boot/efi
for efi_dir in /usr/lib/efi/*/*/EFI; do
  [ -d "${efi_dir}" ] || continue
  cp -ra "${efi_dir}" /boot/efi/
done

# Rebuild initramfs next to the kernel (required for live / generic ISO).
vmlinuz="$(ls -1 /usr/lib/modules/*/vmlinuz | head -n1)"
test -n "${vmlinuz}"
kver="$(basename "$(dirname "${vmlinuz}")")"
DRACUT_NO_XATTR=1 dracut -vf "/usr/lib/modules/${kver}/initramfs.img" "${kver}"

# Not meaningful / harmful on a live (non-installed) root.
systemctl mask bootc-generic-growpart.service || true
systemctl mask bootc-publish-rhsm-facts.service || true

systemctl enable NetworkManager.service
systemctl enable lldpd.service
systemctl enable sshd.service
systemctl enable hw-gather.service

bootc container lint
EOF
