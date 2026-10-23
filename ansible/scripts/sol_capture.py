#!/usr/bin/env python3
"""Capture BMC host serial console until hw-gather markers appear.

Transports:
  ipmi     – IPMI SOL via ipmitool (lanplus). Default.
  redfish  – discover SerialConsole via Redfish, then attach over SSH
             (and try OpenBMC /console0 websocket)
  auto     – try ipmi, then redfish
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import signal
import socket
import ssl
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlparse

BEGIN = "###HW-GATHER-BEGIN###"
END = "###HW-GATHER-END###"
BLOCK_RE = re.compile(
    re.escape(BEGIN) + r"\n(.*)\n" + re.escape(END),
    re.DOTALL,
)


def extract_report(text: str) -> str | None:
    match = BLOCK_RE.search(text)
    return match.group(1) if match else None


def ipmi_session_failed(text: str) -> bool:
    needles = (
        "Unable to establish IPMI",
        "Error: Unable to establish IPMI",
        "unauthorized name",
        "Get Session Challenge command failed",
    )
    lower = text.lower()
    return any(n.lower() in lower for n in needles)


# --------------------------------------------------------------------------- Redfish HTTP


def _ssl_context(validate: bool) -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    if not validate:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def redfish_request(
    url: str,
    username: str,
    password: str,
    validate_certs: bool,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, dict[str, str], Any]:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    token = base64.b64encode(f"{username}:{password}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, context=_ssl_context(validate_certs), timeout=60) as resp:
            raw = resp.read()
            hdrs = {k.lower(): v for k, v in resp.headers.items()}
            if not raw:
                return resp.status, hdrs, None
            try:
                return resp.status, hdrs, json.loads(raw.decode())
            except json.JSONDecodeError:
                return resp.status, hdrs, raw.decode(errors="replace")
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            payload = json.loads(raw.decode()) if raw else None
        except json.JSONDecodeError:
            payload = raw.decode(errors="replace") if raw else None
        return exc.code, {k.lower(): v for k, v in exc.headers.items()}, payload


def normalize_baseuri(baseuri: str) -> str:
    """Return scheme://host[:port] suitable for Redfish roots."""
    if "://" not in baseuri:
        baseuri = "https://" + baseuri
    parsed = urlparse(baseuri)
    netloc = parsed.netloc or parsed.path.split("/")[0]
    return f"{parsed.scheme}://{netloc}"


def redfish_get_json(
    base: str, path: str, username: str, password: str, validate_certs: bool
) -> Any:
    if path.startswith("http"):
        url = path
    else:
        url = base.rstrip("/") + "/" + path.lstrip("/")
    status, _, payload = redfish_request(url, username, password, validate_certs)
    if status >= 400:
        return None
    return payload


def discover_serial_console(
    base: str,
    username: str,
    password: str,
    validate_certs: bool,
    system_id: str,
    manager_id: str,
) -> list[dict[str, Any]]:
    """Return candidate console connection dicts (transport-specific)."""
    candidates: list[dict[str, Any]] = []
    resources: list[str] = []
    if system_id:
        resources.append(f"/redfish/v1/Systems/{system_id}")
    if manager_id:
        resources.append(f"/redfish/v1/Managers/{manager_id}")
    # Always probe Managers collection for SerialConsole / Graphicals hints.
    managers = redfish_get_json(
        base, "/redfish/v1/Managers", username, password, validate_certs
    )
    if isinstance(managers, dict):
        for member in managers.get("Members") or []:
            odata = member.get("@odata.id") if isinstance(member, dict) else None
            if odata and odata not in resources:
                resources.append(odata)

    for path in resources:
        data = redfish_get_json(base, path, username, password, validate_certs)
        if not isinstance(data, dict):
            continue
        serial = data.get("SerialConsole") or data.get("HostSerialConsole")
        if not isinstance(serial, dict):
            continue
        for kind in ("SSH", "Telnet", "IPMI"):
            conf = serial.get(kind)
            if not isinstance(conf, dict):
                continue
            if conf.get("ServiceEnabled") is False:
                continue
            candidates.append(
                {
                    "kind": kind.lower(),
                    "port": int(conf.get("Port") or (22 if kind == "SSH" else 0)),
                    "shared": bool(conf.get("SharedWithManagerCLI", False)),
                    "entry": conf.get("ConsoleEntryCommand") or "",
                    "source": path,
                }
            )

    # Prefer vendor-advertised consoles that look like real host serial,
    # then OpenBMC defaults, then plain SSH:22 (often just the BMC shell).
    ranked: list[dict[str, Any]] = []
    fallbacks: list[dict[str, Any]] = []
    for cand in candidates:
        port = int(cand.get("port") or 0)
        entry = cand.get("entry") or ""
        if cand["kind"] == "ssh" and (entry or port not in (0, 22)):
            ranked.append(cand)
        else:
            fallbacks.append(cand)

    host = urlparse(base).hostname or ""
    ranked.append(
        {
            "kind": "ssh",
            "port": 2200,
            "shared": False,
            "entry": "",
            "source": "openbmc-default-2200",
            "host": host,
        }
    )
    ranked.append(
        {
            "kind": "websocket",
            "path": "/console0",
            "source": "openbmc-websocket",
            "host": host,
        }
    )
    ranked.extend(fallbacks)
    return ranked


# --------------------------------------------------------------------------- readers


def read_until_markers(
    read_line: Callable[[], str | None],
    out_path: Path,
    timeout: int,
    verbose: bool,
) -> tuple[str, int]:
    """Read lines until markers or timeout. Returns (buffer, exit_code).

    exit_code: 0 ok-with-markers-pending-check, 2 timeout, 3 stream ended early
    """
    deadline = time.monotonic() + timeout
    buf = ""
    with out_path.open("w", encoding="utf-8", errors="replace") as fh:
        while time.monotonic() < deadline:
            line = read_line()
            if line is None:
                return buf, 3
            if line == "":
                time.sleep(0.05)
                continue
            fh.write(line)
            fh.flush()
            buf += line
            if verbose:
                sys.stderr.write(line)
                sys.stderr.flush()
            if END in buf and BEGIN in buf and extract_report(buf) is not None:
                return buf, 0
    sys.stderr.write(
        f"ERROR: timed out after {timeout}s waiting for {BEGIN} / {END}\n"
    )
    return buf, 2


def capture_from_popen(
    cmd: list[str],
    out_path: Path,
    timeout: int,
    verbose: bool,
    env: dict[str, str] | None = None,
    stdin_text: str | None = None,
) -> tuple[str, int]:
    proc: subprocess.Popen[str] | None = None
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env or os.environ.copy(),
        )
        assert proc.stdout is not None
        if stdin_text and proc.stdin:
            proc.stdin.write(stdin_text)
            proc.stdin.flush()

        def read_line() -> str | None:
            assert proc is not None and proc.stdout is not None
            if proc.poll() is not None:
                rest = proc.stdout.read()
                return rest if rest else None
            return proc.stdout.readline()

        return read_until_markers(read_line, out_path, timeout, verbose)
    finally:
        if proc and proc.poll() is None:
            try:
                if proc.stdin:
                    proc.stdin.write("\r~.\r")
                    proc.stdin.flush()
            except Exception:
                pass
            time.sleep(0.3)
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


def which(cmd: str) -> str | None:
    from shutil import which as _which

    return _which(cmd)


def capture_ssh(
    host: str,
    port: int,
    username: str,
    password: str,
    entry_cmd: str,
    out_path: Path,
    timeout: int,
    verbose: bool,
) -> tuple[str, int]:
    """Attach over SSH. Prefer sshpass+ssh; fall back to paramiko if present."""
    ssh = which("ssh")
    sshpass = which("sshpass")
    if ssh and sshpass:
        cmd = [
            sshpass,
            "-p",
            password,
            ssh,
            "-tt",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "LogLevel=ERROR",
            "-o",
            "PreferredAuthentications=password",
            "-o",
            "PubkeyAuthentication=no",
            "-p",
            str(port),
            f"{username}@{host}",
        ]
        # Shared CLI: run the vendor console entry command as the remote command.
        if entry_cmd:
            cmd.append(entry_cmd)
        return capture_from_popen(cmd, out_path, timeout, verbose)

    try:
        import paramiko  # type: ignore
    except ImportError:
        raise SystemExit(
            "SSH serial capture needs sshpass+openssh or python3-paramiko. "
            "Install: sudo dnf install -y sshpass openssh-clients"
        ) from None

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        hostname=host,
        port=port,
        username=username,
        password=password,
        look_for_keys=False,
        allow_agent=False,
        timeout=30,
    )
    if entry_cmd:
        _stdin, stdout, _stderr = client.exec_command(entry_cmd, get_pty=True)
        channel = stdout.channel
    else:
        channel = client.invoke_shell(term="vt100", width=120, height=40)

    deadline = time.monotonic() + timeout
    buf = ""
    try:
        with out_path.open("w", encoding="utf-8", errors="replace") as fh:
            while time.monotonic() < deadline:
                if channel.recv_ready():
                    chunk = channel.recv(4096).decode("utf-8", errors="replace")
                    fh.write(chunk)
                    fh.flush()
                    buf += chunk
                    if verbose:
                        sys.stderr.write(chunk)
                        sys.stderr.flush()
                    if END in buf and BEGIN in buf and extract_report(buf) is not None:
                        return buf, 0
                elif channel.exit_status_ready():
                    break
                else:
                    time.sleep(0.05)
            else:
                sys.stderr.write(
                    f"ERROR: timed out after {timeout}s waiting for {BEGIN} / {END}\n"
                )
                return buf, 2
    finally:
        client.close()
    return buf, 3


def _ws_accept_key(key: str) -> str:
    guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    digest = hashlib.sha1((key + guid).encode()).digest()
    return base64.b64encode(digest).decode()


def capture_openbmc_websocket(
    base: str,
    username: str,
    password: str,
    validate_certs: bool,
    out_path: Path,
    timeout: int,
    verbose: bool,
    path: str = "/console0",
) -> tuple[str, int]:
    """OpenBMC bmcweb host console websocket (/console0)."""
    parsed = urlparse(base)
    host = parsed.hostname or ""
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    # Session auth via Redfish sessions (works on many OpenBMC builds).
    status, hdrs, body = redfish_request(
        f"{base.rstrip('/')}/redfish/v1/SessionService/Sessions",
        username,
        password,
        validate_certs,
        method="POST",
        body={"UserName": username, "Password": password},
    )
    token = hdrs.get("x-auth-token") or hdrs.get("x-csrf-token") or ""
    location = hdrs.get("location", "")
    if status >= 400 or not token:
        # Fallback: OpenBMC /login form
        status2, hdrs2, _ = redfish_request(
            f"{base.rstrip('/')}/login",
            username,
            password,
            validate_certs,
            method="POST",
            body={"data": [username, password]},
        )
        # Cookie jar is not automatic; try basic auth on WS instead.
        token = hdrs2.get("x-auth-token") or token
        if status2 >= 400 and not token:
            raise RuntimeError(
                f"OpenBMC/Redfish session login failed (HTTP {status}/{status2})"
            )

    key = base64.b64encode(os.urandom(16)).decode()
    sock = socket.create_connection((host, port), timeout=30)
    if parsed.scheme == "https":
        sock = _ssl_context(validate_certs).wrap_socket(sock, server_hostname=host)

    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
    )
    if token:
        req += f"X-Auth-Token: {token}\r\n"
    # Also send basic auth; some builds accept it on the WS upgrade.
    basic = base64.b64encode(f"{username}:{password}".encode()).decode()
    req += f"Authorization: Basic {basic}\r\n\r\n"
    sock.sendall(req.encode())

    # Read HTTP response headers
    header_data = b""
    while b"\r\n\r\n" not in header_data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        header_data += chunk
    header_text = header_data.decode("iso-8859-1", errors="replace")
    if "101" not in header_text.split("\r\n", 1)[0]:
        sock.close()
        raise RuntimeError(f"websocket upgrade failed: {header_text.split(chr(13), 1)[0]}")

    deadline = time.monotonic() + timeout
    buf = ""
    sock.settimeout(1.0)
    with out_path.open("w", encoding="utf-8", errors="replace") as fh:
        while time.monotonic() < deadline:
            try:
                hdr = sock.recv(2)
                if len(hdr) < 2:
                    time.sleep(0.05)
                    continue
                b1, b2 = hdr[0], hdr[1]
                opcode = b1 & 0x0F
                masked = b2 & 0x80
                length = b2 & 0x7F
                if length == 126:
                    length = struct.unpack("!H", sock.recv(2))[0]
                elif length == 127:
                    length = struct.unpack("!Q", sock.recv(8))[0]
                mask = sock.recv(4) if masked else b""
                payload = b""
                while len(payload) < length:
                    payload += sock.recv(length - len(payload))
                if masked:
                    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
                if opcode in (1, 2):  # text/binary
                    text = payload.decode("utf-8", errors="replace")
                    fh.write(text)
                    fh.flush()
                    buf += text
                    if verbose:
                        sys.stderr.write(text)
                        sys.stderr.flush()
                    if END in buf and BEGIN in buf and extract_report(buf) is not None:
                        sock.close()
                        return buf, 0
                elif opcode == 8:
                    break
            except socket.timeout:
                continue
            except OSError:
                break
    sock.close()
    if time.monotonic() >= deadline:
        sys.stderr.write(
            f"ERROR: timed out after {timeout}s waiting for {BEGIN} / {END}\n"
        )
        return buf, 2
    return buf, 3


# --------------------------------------------------------------------------- IPMI


def require_ipmitool(path: str) -> None:
    if which(path) is None and not Path(path).is_file():
        raise SystemExit(
            f"ipmitool not found ({path!r}). Install it on the control node "
            "(e.g. sudo dnf install -y ipmitool)."
        )


def deactivate_sol(args: argparse.Namespace) -> None:
    cmd = [
        args.ipmitool,
        "-I",
        "lanplus",
        "-H",
        args.host,
        "-U",
        args.username,
        "-p",
        str(args.port),
    ]
    if args.password:
        cmd.extend(["-P", args.password])
    cmd.extend(["sol", "deactivate"])
    subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def capture_ipmi(args: argparse.Namespace, out_path: Path) -> tuple[str, int]:
    require_ipmitool(args.ipmitool)
    deactivate_sol(args)
    time.sleep(1)
    cmd = [
        args.ipmitool,
        "-I",
        "lanplus",
        "-H",
        args.host,
        "-U",
        args.username,
        "-p",
        str(args.port),
    ]
    if args.password:
        cmd.extend(["-P", args.password])
    if args.cipher_suite is not None:
        cmd.extend(["-C", str(args.cipher_suite)])
    cmd.extend(["sol", "activate"])
    env = os.environ.copy()
    env["IPMITOOL_PASSWORD"] = args.password or ""
    buf, code = capture_from_popen(
        cmd, out_path, args.timeout, args.verbose, env=env
    )
    deactivate_sol(args)
    if ipmi_session_failed(buf):
        return buf, 4
    return buf, code


def capture_redfish(args: argparse.Namespace, out_path: Path) -> tuple[str, int]:
    base = normalize_baseuri(args.redfish_baseuri or args.host)
    # If host looks like hostname only, prefer https://host
    if "://" not in (args.redfish_baseuri or ""):
        # Keep port from --redfish-port when baseuri has no port.
        parsed = urlparse(base)
        if not parsed.port and args.redfish_port:
            base = f"{parsed.scheme}://{parsed.hostname}:{args.redfish_port}"

    sys.stderr.write(f"Discovering Redfish SerialConsole at {base} …\n")
    candidates = discover_serial_console(
        base,
        args.username,
        args.password,
        args.redfish_validate_certs,
        args.redfish_system_id,
        args.redfish_manager_id,
    )
    host = urlparse(base).hostname or args.host
    errors: list[str] = []
    n = len(candidates)

    for i, cand in enumerate(candidates):
        kind = cand["kind"]
        # Don't burn the full scrape window on a wrong console endpoint.
        cand_timeout = (
            args.timeout if i == n - 1 else min(args.timeout, 180)
        )
        try:
            if kind == "ssh":
                port = int(cand.get("port") or 22)
                entry = cand.get("entry") or ""
                use_entry = entry if (cand.get("shared") or entry) else ""
                sys.stderr.write(
                    f"Trying SSH serial console {host}:{port} "
                    f"(source={cand.get('source')}, entry={use_entry!r}, "
                    f"timeout={cand_timeout}s)\n"
                )
                buf, code = capture_ssh(
                    host,
                    port,
                    args.username,
                    args.password,
                    use_entry,
                    out_path,
                    cand_timeout,
                    args.verbose,
                )
                if extract_report(buf) is not None:
                    return buf, 0
                # Full timeout only fatal once we already saw the begin marker
                # (report incomplete). Otherwise try the next candidate.
                if code == 2 and BEGIN in buf:
                    return buf, 2
                errors.append(f"ssh:{port} ended without markers (code={code})")
            elif kind == "websocket":
                path = cand.get("path") or "/console0"
                sys.stderr.write(
                    f"Trying OpenBMC websocket {base}{path} "
                    f"(source={cand.get('source')})\n"
                )
                buf, code = capture_openbmc_websocket(
                    base,
                    args.username,
                    args.password,
                    args.redfish_validate_certs,
                    out_path,
                    cand_timeout,
                    args.verbose,
                    path=path,
                )
                if extract_report(buf) is not None:
                    return buf, 0
                if code == 2 and BEGIN in buf:
                    return buf, 2
                errors.append(f"websocket:{path} ended without markers (code={code})")
            elif kind == "telnet":
                errors.append("telnet serial console not implemented")
            elif kind == "ipmi":
                # SerialConsole advertised IPMI — defer to ipmi transport.
                errors.append("SerialConsole.IPMI advertised; use --transport ipmi")
        except Exception as exc:
            errors.append(f"{kind}: {exc}")
            sys.stderr.write(f"  failed: {exc}\n")
            continue

    sys.stderr.write(
        "ERROR: Redfish serial capture failed for all candidates:\n  - "
        + "\n  - ".join(errors)
        + "\n"
    )
    return "", 4


def finalize(buf: str, out_path: Path, report_path: Path) -> int:
    report = extract_report(buf)
    if report is None:
        sys.stderr.write(
            f"ERROR: captured console but markers not found. See {out_path}\n"
        )
        return 3
    report_path.write_text(report + "\n", encoding="utf-8")
    sys.stderr.write(f"Wrote raw SOL capture: {out_path}\n")
    sys.stderr.write(f"Wrote parsed report:   {report_path}\n")
    sys.stdout.write(report)
    if not report.endswith("\n"):
        sys.stdout.write("\n")
    return 0


def capture(args: argparse.Namespace) -> int:
    out_path = Path(args.output)
    report_path = Path(args.report)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)

    transport = args.transport
    attempts: list[str]
    if transport == "auto":
        attempts = ["ipmi", "redfish"]
    else:
        attempts = [transport]

    last_buf = ""
    last_code = 4
    for kind in attempts:
        sys.stderr.write(f"=== serial transport: {kind} ===\n")
        if kind == "redfish":
            last_buf, last_code = capture_redfish(args, out_path)
        else:
            last_buf, last_code = capture_ipmi(args, out_path)
        if extract_report(last_buf) is not None:
            return finalize(last_buf, out_path, report_path)
        if last_code == 2 and BEGIN in last_buf:
            # Saw begin marker but not a complete report — don't switch transport.
            return last_code
        # code 3/4 or empty timeout: try next transport if any

    if last_buf:
        return finalize(last_buf, out_path, report_path)
    return last_code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="BMC address (hostname/IP)")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", default=os.environ.get("IPMI_PASSWORD") or os.environ.get("REDFISH_PASSWORD", ""))
    parser.add_argument("--port", type=int, default=623, help="IPMI port")
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--output", required=True, help="Raw SOL log path")
    parser.add_argument("--report", required=True, help="Parsed report path")
    parser.add_argument("--ipmitool", default="ipmitool")
    parser.add_argument("--cipher-suite", type=int, default=None)
    parser.add_argument(
        "--transport",
        choices=("redfish", "ipmi", "auto"),
        default="ipmi",
        help="Serial capture transport (default: ipmi)",
    )
    parser.add_argument(
        "--redfish-baseuri",
        default="",
        help="Redfish host:port or URL (default: https://--host)",
    )
    parser.add_argument("--redfish-port", type=int, default=0)
    parser.add_argument("--redfish-system-id", default="")
    parser.add_argument("--redfish-manager-id", default="")
    parser.add_argument(
        "--redfish-validate-certs",
        action="store_true",
        default=False,
    )
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if not args.password:
        sys.stderr.write(
            "ERROR: password required (--password or REDFISH_PASSWORD/IPMI_PASSWORD)\n"
        )
        return 1

    return capture(args)


if __name__ == "__main__":
    sys.exit(main())
