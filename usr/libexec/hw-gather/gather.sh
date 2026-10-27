#!/usr/bin/bash
# Collect disk, NIC, and LLDP info; emit a scrapeable block on the serial console.
set -uo pipefail

OUT_DIR="${HW_GATHER_OUT_DIR:-/var/log/hw-gather}"
LLDP_WAIT_SECS="${HW_GATHER_LLDP_WAIT:-45}"
# Unique markers for Redfish / SOL terminal scrapers.
MARKER_BEGIN="${HW_GATHER_MARKER_BEGIN:-###HW-GATHER-BEGIN###}"
MARKER_END="${HW_GATHER_MARKER_END:-###HW-GATHER-END###}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="${OUT_DIR}/report-${STAMP}.txt"
LATEST="${OUT_DIR}/latest.txt"
SERIAL_BLOCK="${OUT_DIR}/serial-${STAMP}.txt"

mkdir -p "${OUT_DIR}"

log() {
  printf '%s\n' "$*" >>"${REPORT}"
}

section() {
  log ""
  log "================================================================================"
  log "$*"
  log "================================================================================"
}

serial_progress() {
  local msg="$1"
  local target
  # Prefer console= UARTs only (see emit_targets).
  for target in $(emit_targets 2>/dev/null || serial_targets); do
    [[ -c "${target}" ]] || continue
    # Prefer a short timeout so a stuck UART cannot freeze inventory.
    timeout 1 bash -c "printf 'hw-gather: %s\n' \"\$1\" >\"\$2\"" _ "${msg}" "${target}" \
      2>/dev/null || true
  done
}

run_cmd() {
  local title="$1"
  shift
  local rc=0
  local output=""
  section "${title}"
  log "+ $*"
  # lldpcli / smart tooling can block forever on a wedged daemon; never stall emit.
  if output="$(timeout 30 "$@" 2>&1)"; then
    log "${output}"
  else
    rc=$?
    log "${output}"
    log "(exit ${rc})"
  fi
  serial_progress "done: ${title}"
}

bring_up_nics() {
  local iface
  for iface in /sys/class/net/*; do
    iface="${iface##*/}"
    case "${iface}" in
      lo|bonding_masters) continue ;;
    esac
    ip link set dev "${iface}" up 2>/dev/null || true
  done
}

wait_for_lldp() {
  local elapsed=0
  local neighbors=""

  section "Waiting up to ${LLDP_WAIT_SECS}s for LLDP neighbors"
  serial_progress "waiting up to ${LLDP_WAIT_SECS}s for LLDP neighbors"
  while (( elapsed < LLDP_WAIT_SECS )); do
    if systemctl is-active --quiet lldpd.service 2>/dev/null; then
      neighbors="$(timeout 5 lldpcli show neighbors 2>/dev/null || true)"
      if grep -qE 'Interface:|ChassisID:|SysName:|PortID:' <<<"${neighbors}"; then
        log "LLDP neighbors detected after ${elapsed}s"
        serial_progress "LLDP neighbors detected after ${elapsed}s"
        return 0
      fi
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    if (( elapsed % 10 == 0 )); then
      serial_progress "LLDP wait ${elapsed}/${LLDP_WAIT_SECS}s"
    fi
  done
  log "Timed out waiting for LLDP neighbors (switches must have LLDP enabled)"
  serial_progress "LLDP wait timed out; emitting report next"
}

# Resolve BMC UART devices Redfish SOL / VirtualBMC typically mirror.
# Prefer console= UARTs from the cmdline; never treat /dev/console as enough
# on its own (with console=tty0,console=ttyS0 writes often go to VGA only).
serial_targets() {
  local -a found=()
  local token dev

  if [[ -r /proc/cmdline ]]; then
    for token in $(tr ' ' '\n' </proc/cmdline | grep '^console='); do
      token="${token#console=}"
      dev="${token%%,*}"
      case "${dev}" in
        ttyS[0-9]*|ttyAMA[0-9]*|ttyUSB[0-9]*|ttyACM[0-9]*|hvc[0-9]*)
          found+=("/dev/${dev}")
          ;;
      esac
    done
  fi

  found+=("/dev/ttyS0" "/dev/ttyS1" "/dev/ttyAMA0")

  printf '%s\n' "${found[@]}" | awk 'NF && !seen[$0]++'
}

stop_serial_gettys() {
  # Keep login prompts from interleaving with the scrape block on SOL.
  local unit
  for unit in serial-getty@ttyS0.service serial-getty@ttyS1.service \
              serial-getty@ttyAMA0.service getty@ttyS0.service; do
    systemctl stop "${unit}" 2>/dev/null || true
  done
}

# UARTs from console= only — spare ttyS1/ttyAMA0 often have no host reader and
# a blocking write there hangs the oneshot forever after "emitting scrape block".
emit_targets() {
  local -a found=()
  local token dev

  if [[ -r /proc/cmdline ]]; then
    for token in $(tr ' ' '\n' </proc/cmdline | grep '^console='); do
      token="${token#console=}"
      dev="${token%%,*}"
      case "${dev}" in
        ttyS[0-9]*|ttyAMA[0-9]*|ttyUSB[0-9]*|ttyACM[0-9]*|hvc[0-9]*)
          found+=("/dev/${dev}")
          ;;
      esac
    done
  fi
  if ((${#found[@]} == 0)); then
    found+=("/dev/ttyS0")
  fi
  printf '%s\n' "${found[@]}" | awk 'NF && !seen[$0]++'
}

emit_to_serial() {
  local path="$1"
  local target
  local wrote=0
  local size
  local out=""

  stop_serial_gettys
  sleep 1

  size="$(wc -c <"${path}" | tr -d ' ')"

  while IFS= read -r target; do
    [[ -c "${target}" ]] || continue
    stty -F "${target}" raw -echo -ixon -ixoff -crtscts clocal cread 115200 2>/dev/null || true
    # Non-blocking write: kernel tty writes can sit in D-state where timeout(1)
    # cannot kill them; O_NONBLOCK + wall clock avoids that hang.
    if out="$(
      TARGET="${target}" PATH_IN="${path}" python3 - <<'PY' 2>&1
import errno
import os
import time

target = os.environ["TARGET"]
path = os.environ["PATH_IN"]
data = open(path, "rb").read()
fd = os.open(target, os.O_WRONLY | os.O_NONBLOCK | os.O_NOCTTY)
deadline = time.monotonic() + 90.0
off = 0
try:
    while off < len(data):
        if time.monotonic() >= deadline:
            raise TimeoutError(f"serial write timed out at {off}/{len(data)}")
        try:
            n = os.write(fd, data[off : off + 256])
        except BlockingIOError:
            time.sleep(0.02)
            continue
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                time.sleep(0.02)
                continue
            raise
        if n == 0:
            time.sleep(0.02)
            continue
        off += n
finally:
    os.close(fd)
print(f"nb-write {off}/{len(data)} -> {target}")
raise SystemExit(0 if off == len(data) else 1)
PY
    )"; then
      wrote=1
      printf 'hw-gather: wrote scrape block to %s (%s bytes)\n' \
        "${target}" "${size}" >&2
      printf '%s\n' "${out}" >&2
    else
      printf 'hw-gather: write to %s failed: %s\n' "${target}" "${out}" >&2
    fi
  done < <(emit_targets)

  if [[ "${wrote}" -eq 0 ]]; then
    printf 'hw-gather: ERROR no serial UART accepted the scrape block\n' >&2
    return 1
  fi
  return 0
}

# Claim the UART immediately so getty cannot hold it during the long LLDP wait.
stop_serial_gettys
for _t in $(emit_targets); do
  [[ -c "${_t}" ]] || continue
  stty -F "${_t}" raw -echo -ixon -ixoff -crtscts clocal cread 115200 2>/dev/null || true
  timeout 1 bash -c "printf '\nhw-gather: collecting inventory (markers follow when done)…\n' >\"\$1\"" _ "${_t}" \
    2>/dev/null || true
done

: >"${REPORT}"

section "Host"
log "Hostname: $(hostnamectl --static 2>/dev/null || hostname)"
log "UTC time: ${STAMP}"
log "Kernel:   $(uname -r)"
log "Product:  $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
log "Serial:   $(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo unknown)"
log "UUID:     $(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo unknown)"

run_cmd "Block devices (lsblk)" \
  lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MODEL,SERIAL,WWN,TRAN,ROTA,STATE,MOUNTPOINTS

run_cmd "Disk IDs (/dev/disk/by-id)" \
  bash -c 'ls -l /dev/disk/by-id 2>/dev/null || echo "(none)"'

if command -v smartctl >/dev/null 2>&1; then
  section "SMART summary (per disk)"
  while read -r disk; do
    [[ -z "${disk}" ]] && continue
    log ""
    log "--- ${disk} ---"
    # virtio / empty QEMU disks can hang smartctl; never block emit.
    timeout 8 smartctl -i -H "${disk}" >>"${REPORT}" 2>&1 || \
      log "(smartctl skipped or timed out on ${disk})"
  done < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
fi

bring_up_nics
sleep 3
serial_progress "NICs up; collecting network inventory"

run_cmd "Network interfaces (ip -d addr)" ip -d addr
run_cmd "Routing" ip route
run_cmd "PCI network devices" bash -c "lspci -nn | grep -iE 'ethernet|network' || true"

section "ethtool per interface"
for iface in /sys/class/net/*; do
  iface="${iface##*/}"
  case "${iface}" in
    lo|bonding_masters) continue ;;
  esac
  log ""
  log "--- ${iface} ---"
  {
    timeout 10 ethtool "${iface}" 2>&1 || true
    timeout 10 ethtool -i "${iface}" 2>&1 || true
    timeout 10 ethtool -P "${iface}" 2>&1 || true
  } >>"${REPORT}"
done
serial_progress "ethtool done"

wait_for_lldp

run_cmd "LLDP neighbors (switch / port mapping)" lldpcli show neighbors details
run_cmd "LLDP statistics" lldpcli show statistics
run_cmd "LLDP interfaces" lldpcli show interfaces details

section "Done"
log "Full report: ${REPORT}"
log "Latest:      ${LATEST}"

ln -sfn "${REPORT}" "${LATEST}"

serial_progress "building scrape block"

# Build one scrapeable serial payload (markers + body + markers).
{
  printf '\n%s\n' "${MARKER_BEGIN}"
  printf 'hw-gather-version: 1\n'
  printf 'utc: %s\n' "${STAMP}"
  printf 'hostname: %s\n' "$(hostnamectl --static 2>/dev/null || hostname)"
  printf '\n'
  cat "${REPORT}"
  printf '\n%s\n\n' "${MARKER_END}"
} >"${SERIAL_BLOCK}"

serial_progress "emitting scrape block ($(wc -c <"${SERIAL_BLOCK}" | tr -d ' ') bytes)"
emit_to_serial "${SERIAL_BLOCK}"
emit_rc=$?

# Also keep a copy in the journal for debugging (includes markers).
systemd-cat -t hw-gather <"${SERIAL_BLOCK}" 2>/dev/null || true

exit "${emit_rc}"
