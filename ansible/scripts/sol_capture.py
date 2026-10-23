#!/usr/bin/env python3
"""Capture BMC Serial-over-LAN until hw-gather markers appear, then extract the report.

Primary transport: IPMI SOL via ipmitool (works with most Redfish BMCs that
still expose IPMI-over-LAN). Output is written to --output and the parsed
report body to --report.
"""

from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

BEGIN = "###HW-GATHER-BEGIN###"
END = "###HW-GATHER-END###"
BLOCK_RE = re.compile(
    re.escape(BEGIN) + r"\n(.*)\n" + re.escape(END),
    re.DOTALL,
)


def build_ipmitool_cmd(args: argparse.Namespace) -> list[str]:
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
    cmd.extend(["sol", "activate"])
    return cmd


def require_ipmitool(path: str) -> None:
    from shutil import which

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


def extract_report(text: str) -> str | None:
    match = BLOCK_RE.search(text)
    return match.group(1) if match else None


def capture(args: argparse.Namespace) -> int:
    out_path = Path(args.output)
    report_path = Path(args.report)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)

    require_ipmitool(args.ipmitool)
    deactivate_sol(args)
    time.sleep(1)

    cmd = build_ipmitool_cmd(args)
    env = os.environ.copy()
    # Avoid ipmitool prompting.
    env["IPMITOOL_PASSWORD"] = args.password or ""

    deadline = time.monotonic() + args.timeout
    buf = ""
    proc: subprocess.Popen[str] | None = None

    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env,
        )
        assert proc.stdout is not None

        with out_path.open("w", encoding="utf-8", errors="replace") as fh:
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    rest = proc.stdout.read() or ""
                    fh.write(rest)
                    buf += rest
                    break

                line = proc.stdout.readline()
                if not line:
                    time.sleep(0.05)
                    continue
                fh.write(line)
                fh.flush()
                buf += line
                if args.verbose:
                    sys.stderr.write(line)
                    sys.stderr.flush()
                if END in buf and BEGIN in buf and extract_report(buf) is not None:
                    break
            else:
                sys.stderr.write(
                    f"ERROR: timed out after {args.timeout}s waiting for "
                    f"{BEGIN} / {END}\n"
                )
                return 2
    finally:
        if proc and proc.poll() is None:
            # Try graceful SOL escape (~.) then kill.
            try:
                if proc.stdin:
                    proc.stdin.write("\r~.\r")
                    proc.stdin.flush()
            except Exception:
                pass
            time.sleep(0.5)
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        deactivate_sol(args)

    report = extract_report(buf)
    if report is None:
        sys.stderr.write(
            f"ERROR: captured console but markers not found. See {out_path}\n"
        )
        return 3

    report_path.write_text(report + "\n", encoding="utf-8")
    sys.stderr.write(f"Wrote raw SOL capture: {out_path}\n")
    sys.stderr.write(f"Wrote parsed report:   {report_path}\n")
    # Print report to stdout for Ansible to display / register.
    sys.stdout.write(report)
    if not report.endswith("\n"):
        sys.stdout.write("\n")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="BMC address")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", default=os.environ.get("IPMI_PASSWORD", ""))
    parser.add_argument("--port", type=int, default=623)
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--output", required=True, help="Raw SOL log path")
    parser.add_argument("--report", required=True, help="Parsed report path")
    parser.add_argument("--ipmitool", default="ipmitool")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if not args.password:
        sys.stderr.write("ERROR: password required (--password or IPMI_PASSWORD)\n")
        return 1

    return capture(args)


if __name__ == "__main__":
    sys.exit(main())
