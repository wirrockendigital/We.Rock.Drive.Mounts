#!/usr/bin/env python3
"""Bounded Raspberry Pi companion for network diagnostics and Wake-on-LAN."""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import os
import pathlib
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import uuid

VERSION = "0.2.0"
STATE_ROOT = pathlib.Path("/var/lib/we-rock-drive-mounts")
CAPTURE_ROOT = STATE_ROOT / "captures"
LOG_ROOT = pathlib.Path("/var/log/we-rock-drive-mounts")
SYSLOG_FILE = LOG_ROOT / "synology.log"
MAC_PATTERN = re.compile(r"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")
INTERFACE_PATTERN = re.compile(r"^[A-Za-z0-9_.:-]{1,32}$")
HOST_PATTERN = re.compile(r"^[A-Za-z0-9_.:-]{1,253}$")


def utc_now() -> str:
    """Return an ISO 8601 UTC timestamp accepted by Swift's decoder."""
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def emit(payload: dict[str, object]) -> None:
    """Write one machine-readable response to stdout."""
    print(json.dumps(payload, sort_keys=True), flush=True)


def executable(name: str) -> str | None:
    """Resolve one approved external command by name."""
    return shutil.which(name)


def service_is_active() -> bool:
    """Check the managed syslog receiver without treating systemd errors as fatal."""
    systemctl = executable("systemctl")
    if not systemctl:
        return False
    result = subprocess.run(
        [systemctl, "is-active", "--quiet", "wrdm-syslog.service"],
        check=False,
        timeout=5,
    )
    return result.returncode == 0


def health(_: argparse.Namespace) -> int:
    """Report companion and dependency capabilities."""
    hostname_result = subprocess.run(
        [executable("hostname") or "/bin/hostname", "-I"],
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
    )
    addresses = [value for value in hostname_result.stdout.split() if value]
    emit(
        {
            "ok": True,
            "version": VERSION,
            "hostname": socket.gethostname(),
            "architecture": platform.machine(),
            "addresses": addresses,
            "dumpcapAvailable": executable("dumpcap") is not None,
            "tsharkAvailable": executable("tshark") is not None,
            "syslogReceiverActive": service_is_active(),
            "wakeAvailable": True,
        }
    )
    return 0


def managed_capture_root(value: str) -> pathlib.Path:
    """Resolve one configurable capture directory inside the managed state root."""
    state_root = STATE_ROOT.resolve()
    capture_root = pathlib.Path(value).resolve()
    if capture_root == state_root or state_root not in capture_root.parents:
        raise ValueError("Capture directory must be inside the managed state directory")
    return capture_root


def prune_captures(
    maximum_files: int,
    maximum_bytes: int,
    capture_root: pathlib.Path | None = None,
) -> None:
    """Remove oldest captures until both configured retention bounds are met."""
    capture_root = capture_root or CAPTURE_ROOT
    capture_root.mkdir(parents=True, exist_ok=True)
    files = sorted(
        (path for path in capture_root.glob("*.pcapng") if path.is_file()),
        key=lambda path: path.stat().st_mtime,
    )
    total = sum(path.stat().st_size for path in files)
    while files and (len(files) > maximum_files or total > maximum_bytes):
        oldest = files.pop(0)
        size = oldest.stat().st_size
        oldest.unlink(missing_ok=True)
        total -= size


def capture(arguments: argparse.Namespace) -> int:
    """Capture one filtered, duration-bounded PCAPNG session."""
    if not INTERFACE_PATTERN.fullmatch(arguments.interface):
        raise ValueError("Invalid network interface")
    if not (pathlib.Path("/sys/class/net") / arguments.interface).exists():
        raise ValueError("Network interface does not exist")
    if arguments.host and not HOST_PATTERN.fullmatch(arguments.host):
        raise ValueError("Invalid capture host")
    tool = executable("dumpcap") or executable("tshark")
    if not tool:
        raise RuntimeError("Neither dumpcap nor tshark is installed")

    seconds = max(1, min(arguments.seconds, 300))
    maximum_files = max(1, min(arguments.max_files, 200))
    maximum_bytes = max(1_048_576, min(arguments.max_bytes, 10_737_418_240))
    capture_root = managed_capture_root(arguments.directory)
    prune_captures(maximum_files - 1, maximum_bytes, capture_root)

    session_id = str(uuid.uuid4())
    started_at = utc_now()
    destination = capture_root / f"capture-{int(time.time())}-{session_id}.pcapng"
    capture_filter = "tcp port 445 or icmp or arp"
    if arguments.host:
        capture_filter = f"host {arguments.host} and ({capture_filter})"
    command = [
        tool,
        "-i",
        arguments.interface,
        "-f",
        capture_filter,
        "-w",
        str(destination),
        "-a",
        f"duration:{seconds}",
    ]
    result = subprocess.run(
        command,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        timeout=seconds + 15,
    )
    if result.returncode != 0 or not destination.exists():
        destination.unlink(missing_ok=True)
        raise RuntimeError((result.stderr or "Packet capture failed")[:500])
    if destination.stat().st_size > maximum_bytes:
        destination.unlink(missing_ok=True)
        raise RuntimeError("Capture exceeded the configured storage limit")
    prune_captures(maximum_files, maximum_bytes, capture_root)
    emit(
        {
            "id": session_id,
            "startedAt": started_at,
            "host": arguments.host or "",
            "interface": arguments.interface,
            "filter": capture_filter,
            "remotePath": str(destination),
            "localPath": None,
            "sizeBytes": destination.stat().st_size,
        }
    )
    return 0


def managed_capture_file(value: str) -> pathlib.Path:
    """Resolve one existing PCAPNG file inside the managed state root."""
    state_root = STATE_ROOT.resolve()
    capture_file = pathlib.Path(value).resolve()
    if state_root not in capture_file.parents or capture_file.suffix.lower() != ".pcapng":
        raise ValueError("Capture file must be a managed PCAPNG file")
    if not capture_file.is_file():
        raise ValueError("Capture file does not exist")
    return capture_file


def summarize_packet_rows(rows: list[str]) -> dict[str, object]:
    """Aggregate bounded tshark fields without retaining packet payloads or addresses."""
    protocol_counts: collections.Counter[str] = collections.Counter()
    conversations: set[tuple[str, str]] = set()
    first_timestamp: float | None = None
    last_timestamp: float | None = None
    retransmissions = 0
    reset_packets = 0
    icmp_errors = 0
    packet_count = 0
    for row in rows:
        fields = row.rstrip("\n").split("\t")
        fields.extend([""] * (7 - len(fields)))
        timestamp, protocols, retransmission, reset, icmp_type, source, target = fields[:7]
        packet_count += 1
        try:
            numeric_timestamp = float(timestamp)
            first_timestamp = numeric_timestamp if first_timestamp is None else min(first_timestamp, numeric_timestamp)
            last_timestamp = numeric_timestamp if last_timestamp is None else max(last_timestamp, numeric_timestamp)
        except ValueError:
            pass
        for protocol in {value for value in protocols.split(":") if value}:
            protocol_counts[protocol] += 1
        retransmissions += int(bool(retransmission))
        reset_packets += int(reset == "1")
        icmp_errors += int(icmp_type in {"3", "4", "5", "11", "12"})
        if source and target:
            conversations.add(tuple(sorted((source, target))))
    duration = 0.0
    if first_timestamp is not None and last_timestamp is not None:
        duration = max(0.0, last_timestamp - first_timestamp)
    # Mixed tagged and untagged frames can indicate mirrored duplicates, but remain evidence rather than a conclusion.
    mixed_vlan_tagging = 0 < protocol_counts.get("vlan", 0) < packet_count
    return {
        "packetCount": packet_count,
        "durationSeconds": duration,
        "protocolCounts": dict(sorted(protocol_counts.items())),
        "tcpRetransmissions": retransmissions,
        "tcpResetPackets": reset_packets,
        "icmpErrors": icmp_errors,
        "conversationCount": len(conversations),
        "mirrorDuplicationPossible": mixed_vlan_tagging,
    }


def capture_summary(arguments: argparse.Namespace) -> int:
    """Summarize one managed capture with tshark while excluding payloads and endpoint addresses."""
    capture_file = managed_capture_file(arguments.file)
    tshark = executable("tshark")
    if not tshark:
        raise RuntimeError("tshark is not installed")
    result = subprocess.run(
        [
            tshark,
            "-r",
            str(capture_file),
            "-T",
            "fields",
            "-E",
            "separator=/t",
            "-e",
            "frame.time_epoch",
            "-e",
            "frame.protocols",
            "-e",
            "tcp.analysis.retransmission",
            "-e",
            "tcp.flags.reset",
            "-e",
            "icmp.type",
            "-e",
            "ip.src",
            "-e",
            "ip.dst",
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError((result.stderr or "Capture analysis failed")[:500])
    summary = summarize_packet_rows(result.stdout.splitlines())
    summary["ok"] = True
    emit(summary)
    return 0


def stream(arguments: argparse.Namespace) -> int:
    """Stream a bounded PCAPNG capture to stdout for a local Wireshark process."""
    if not INTERFACE_PATTERN.fullmatch(arguments.interface):
        raise ValueError("Invalid network interface")
    if not (pathlib.Path("/sys/class/net") / arguments.interface).exists():
        raise ValueError("Network interface does not exist")
    if arguments.host and not HOST_PATTERN.fullmatch(arguments.host):
        raise ValueError("Invalid capture host")
    tool = executable("dumpcap") or executable("tshark")
    if not tool:
        raise RuntimeError("Neither dumpcap nor tshark is installed")
    capture_filter = "tcp port 445 or icmp or arp"
    if arguments.host:
        capture_filter = f"host {arguments.host} and ({capture_filter})"
    result = subprocess.run(
        [tool, "-i", arguments.interface, "-f", capture_filter, "-w", "-"],
        check=False,
        stdout=sys.stdout.buffer,
        stderr=sys.stderr,
    )
    return result.returncode


def syslog_tail(arguments: argparse.Namespace) -> int:
    """Return a bounded suffix of the received Synology log."""
    maximum = max(1, min(arguments.lines, 5_000))
    if not SYSLOG_FILE.exists():
        return 0
    with SYSLOG_FILE.open("r", encoding="utf-8", errors="replace") as handle:
        for line in collections.deque(handle, maxlen=maximum):
            print(line.rstrip("\n"))
    return 0


def rotate_syslog(maximum_bytes: int = 52_428_800, backups: int = 5) -> None:
    """Rotate the receiver log before appending beyond its bounded size."""
    if not SYSLOG_FILE.exists() or SYSLOG_FILE.stat().st_size < maximum_bytes:
        return
    oldest = SYSLOG_FILE.with_suffix(f".log.{backups}")
    oldest.unlink(missing_ok=True)
    for index in range(backups - 1, 0, -1):
        source = SYSLOG_FILE.with_suffix(f".log.{index}")
        if source.exists():
            source.rename(SYSLOG_FILE.with_suffix(f".log.{index + 1}"))
    SYSLOG_FILE.rename(SYSLOG_FILE.with_suffix(".log.1"))


def syslog_receive(arguments: argparse.Namespace) -> int:
    """Receive UDP syslog records and preserve arrival timestamps plus raw messages."""
    LOG_ROOT.mkdir(parents=True, exist_ok=True)
    running = True

    def stop(_: int, __: object) -> None:
        """Request a clean receiver shutdown from systemd signals."""
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    receiver.bind((arguments.bind, arguments.port))
    receiver.settimeout(1)
    while running:
        try:
            payload, address = receiver.recvfrom(65_507)
        except socket.timeout:
            continue
        message = payload.decode("utf-8", errors="replace").replace("\x00", "").strip()
        rotate_syslog()
        with SYSLOG_FILE.open("a", encoding="utf-8") as handle:
            handle.write(f"{utc_now()} receiver={address[0]} {message}\n")
    receiver.close()
    return 0


def magic_packet(mac_address: str) -> bytes:
    """Construct a standards-compliant Wake-on-LAN magic packet."""
    if not MAC_PATTERN.fullmatch(mac_address) or mac_address.lower() == "ff:ff:ff:ff:ff:ff":
        raise ValueError("Invalid MAC address")
    target = bytes.fromhex(mac_address.replace(":", ""))
    return b"\xff" * 6 + target * 16


def wake(arguments: argparse.Namespace) -> int:
    """Broadcast one Wake-on-LAN packet from the always-on Pi."""
    packet = magic_packet(arguments.mac)
    sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sender.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    for _ in range(3):
        sender.sendto(packet, (arguments.broadcast, arguments.port))
        time.sleep(0.2)
    sender.close()
    emit({"ok": True, "mac": arguments.mac.lower(), "broadcast": arguments.broadcast})
    return 0


def parser() -> argparse.ArgumentParser:
    """Build the explicit companion command grammar."""
    root = argparse.ArgumentParser(prog="wrdm-companion")
    root.add_argument("--version", action="version", version=VERSION)
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("health").set_defaults(handler=health)

    capture_parser = commands.add_parser("capture")
    capture_parser.add_argument("--interface", required=True)
    capture_parser.add_argument("--seconds", type=int, default=20)
    capture_parser.add_argument("--max-files", type=int, default=20)
    capture_parser.add_argument("--max-bytes", type=int, default=104_857_600)
    capture_parser.add_argument("--directory", default=str(CAPTURE_ROOT))
    capture_parser.add_argument("--host")
    capture_parser.set_defaults(handler=capture)

    summary_parser = commands.add_parser("capture-summary")
    summary_parser.add_argument("--file", required=True)
    summary_parser.set_defaults(handler=capture_summary)

    stream_parser = commands.add_parser("stream")
    stream_parser.add_argument("--interface", required=True)
    stream_parser.add_argument("--host")
    stream_parser.set_defaults(handler=stream)

    tail_parser = commands.add_parser("syslog-tail")
    tail_parser.add_argument("--lines", type=int, default=500)
    tail_parser.set_defaults(handler=syslog_tail)

    receiver_parser = commands.add_parser("syslog-receive")
    receiver_parser.add_argument("--bind", default="0.0.0.0")
    receiver_parser.add_argument("--port", type=int, default=5514)
    receiver_parser.set_defaults(handler=syslog_receive)

    wake_parser = commands.add_parser("wake")
    wake_parser.add_argument("--mac", required=True)
    wake_parser.add_argument("--broadcast", default="255.255.255.255")
    wake_parser.add_argument("--port", type=int, default=9)
    wake_parser.set_defaults(handler=wake)
    return root


def main() -> int:
    """Execute one command and return bounded errors on stderr."""
    arguments = parser().parse_args()
    try:
        return int(arguments.handler(arguments))
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(str(error)[:500], file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
