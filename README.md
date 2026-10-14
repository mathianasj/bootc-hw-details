# bootc-hw-gather

RHEL 9 **image mode** (`bootc`) image that, on every boot, prints and saves:

- Disk / block-device inventory (`lsblk`, by-id links, SMART)
- Network interface details (`ip`, `ethtool`, PCI NICs)
- **LLDP neighbors** (`lldpd` / `lldpcli`) so you can see which NIC is on which switch port

On boot the full report is written **once** to the serial console (Redfish SOL / BMC UART) as a single scrapeable block between markers. A copy is also saved under `/var/log/hw-gather/`.

The ISO is a **live** image (`rd.live.image` / squashfs). It boots and runs in RAM overlay — it does **not** install to or wipe disks.

## Prerequisites

- Active RHEL subscription / access to `registry.redhat.io`
- Podman (or compatible build tool)
- Logged in: `podman login registry.redhat.io`

LLDP only works if the attached switch has LLDP (or compatible CDP receive) enabled on the port.

## Ansible: build live ISO → Redfish virtual media → SOL scrape

End-to-end flow on the control node:

1. Build the bootc image (live-capable initramfs + `iso.yaml`)
2. Build a **live** ISO with titanoboa (no Anaconda, no disk install)
3. Serve the ISO over HTTP (BMC must reach the control node)
4. Mount it with Redfish virtual media, one-time boot to CD, power cycle
5. Attach IPMI SOL, wait for `###HW-GATHER-BEGIN###` … `###HW-GATHER-END###`
6. Write the parsed report under `output/captures/<bmc>/`

### Control-node deps

**RHEL 9** (Python 3.9) — prefer RPMs, not pip Ansible 14:

```bash
sudo dnf install -y ansible-core python3-pip ipmitool
ansible-galaxy collection install -r ansible/requirements.yml
```

Or venv + pip (installs **Ansible 8.x**, the last series that supports Python 3.9):

```bash
sudo dnf install -y python3-pip python3-venv ipmitool
./scripts/setup-ansible.sh
source .venv/bin/activate
```

Manual venv on RHEL 9:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -U pip
pip install -r requirements.txt
ansible-galaxy collection install -r ansible/requirements.yml
```

`requirements.txt` picks Ansible by Python version:

| Python | Ansible | Typical OS |
|--------|---------|------------|
| 3.9 | 8.x | RHEL 9 |
| 3.10–3.11 | 9–12 | |
| 3.12+ | 14+ | Fedora macOS Homebrew |

Do **not** use `ansible>=14` on RHEL 9’s system Python — that is what causes `No matching distribution found`.

### Configure and run

```bash
cp ansible/inventory.example.yml ansible/inventory.yml
# edit redfish_address / redfish_username (password via env)

export REDFISH_PASSWORD='your-bmc-password'

cd ansible
ansible-playbook -i inventory.yml playbook.yml \
  -e redfish_address=10.0.0.50 \
  -e redfish_username=admin
```

Skip rebuild on later runs:

```bash
ansible-playbook -i inventory.yml playbook.yml \
  -e skip_build=true \
  -e redfish_address=10.0.0.50 \
  -e redfish_username=admin
```

Tags: `build`, `deploy`, `capture`.

### Outputs

| Path | Content |
|------|---------|
| `output/iso/bootc-hw-gather.iso` | Staged **live** ISO |
| `output/captures/<bmc>/sol-raw.log` | Full SOL transcript |
| `output/captures/<bmc>/hw-gather-report.txt` | Parsed report (markers stripped) |

### Vendor knobs

| Variable | Notes |
|----------|--------|
| `redfish_vm_category` | `Manager` (default) or `Systems` |
| `redfish_vm_resource_id` | e.g. `BMC`, `1`, `iDRAC.Embedded.1` |
| `redfish_system_id` | System resource for boot/power |
| `iso_http_host` | Address the **BMC** uses to fetch the ISO (not `127.0.0.1`) |
| `iso_http_port` | Default `8080` — open in firewall toward the BMC |
| `sol_timeout_seconds` | Default `900` (live boot + LLDP wait) |

SOL uses **IPMI-over-LAN** (`ipmitool sol activate`) against the same BMC address/creds by default. Enable IPMI/SOL on the BMC if it is disabled.

## Manual build (live ISO)

```bash
sudo podman build \
  --cap-add sys_admin \
  --security-opt label=disable \
  -t localhost/bootc-hw-gather:latest .

mkdir -p output
sudo podman run --rm --privileged \
  --security-opt label=disable \
  -v ./output:/output \
  -v /var/lib/containers/storage:/usr/lib/containers/storage:ro \
  --mount type=image,source=localhost/bootc-hw-gather:latest,dst=/rootfs \
  ghcr.io/ublue-os/titanoboa:latest
```

Live boot is configured in `usr/lib/bootc-image-builder/iso.yaml` (`root=live:CDLABEL=HWGATHER rd.live.image`).

Optional: push the container for use as a normal bootc disk image too:

```bash
podman tag localhost/bootc-hw-gather:latest quay.io/<you>/bootc-hw-gather:latest
podman push quay.io/<you>/bootc-hw-gather:latest
```

## Redfish SOL scraping

After LLDP collection finishes, the service emits **one** block to serial devices:

```text
###HW-GATHER-BEGIN###
hw-gather-version: 1
utc: 20261014T143000Z
hostname: ...

================================================================================
Host
...
================================================================================
LLDP neighbors (switch / port mapping)
...

###HW-GATHER-END###
```

Scrape with Redfish Serial-over-LAN / virtual console, then extract between the markers. Example:

```python
import re
text = open("sol-capture.txt").read()
m = re.search(
    r"###HW-GATHER-BEGIN###\n(.*)\n###HW-GATHER-END###",
    text,
    re.S,
)
report = m.group(1) if m else None
```

The image sets kernel args `console=tty0 console=ttyS0,115200n8` via `usr/lib/bootc/kargs.d/10-serial-console.toml`. If your BMC UART is `ttyS1`, change that file before building.

Emission targets (in order, de-duplicated): `console=` devices from `/proc/cmdline`, then `/dev/console`, `/dev/ttyS0`, `/dev/ttyS1`, `/dev/ttyAMA0`.

## After boot — where to look

| Location | What |
|----------|------|
| Redfish SOL / serial | Full marked report (`###HW-GATHER-BEGIN###` … `###HW-GATHER-END###`) |
| `/var/log/hw-gather/latest.txt` | Same report body (no markers) |
| `/var/log/hw-gather/serial-*.txt` | Exact serial payload including markers |
| `journalctl -t hw-gather -b` | Copy of the serial payload |
| `lldpcli show neighbors details` | Live LLDP view |

Useful LLDP fields for cabling:

- **Interface** — local NIC name
- **SysName** / **ChassisID** — switch identity
- **PortID** / **PortDescr** — switch port

## Tunables

Environment on the unit (override with a drop-in under `/etc/systemd/system/hw-gather.service.d/`):

| Variable | Default | Meaning |
|----------|---------|---------|
| `HW_GATHER_LLDP_WAIT` | `45` | Seconds to wait for neighbors before dumping |
| `HW_GATHER_OUT_DIR` | `/var/log/hw-gather` | Report directory |
| `HW_GATHER_MARKER_BEGIN` | `###HW-GATHER-BEGIN###` | Start marker for scrapers |
| `HW_GATHER_MARKER_END` | `###HW-GATHER-END###` | End marker for scrapers |

Re-run manually (re-emits to serial):

```bash
systemctl start hw-gather.service
```

## Notes

- Collection runs quietly to a file first, then the complete marked block is written to serial — better for terminal scrapers than streaming mid-run.
- Serial gettys on common UART names are stopped briefly before emit so a login prompt does not corrupt the scrape.
- The gather unit brings non-loopback NICs administratively `up` so LLDP can run even without DHCP.
- SSH (`sshd`) is enabled for remote collection; set passwords / inject keys via your usual bootc `/etc` customization or Ignition/cloud-init if you add those.
- Switches must advertise LLDP; silent ports produce an empty neighbor section after the wait timeout.
