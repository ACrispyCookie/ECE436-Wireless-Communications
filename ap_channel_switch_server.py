#!/usr/bin/env python3
"""UDP listener that switches a hostapd AP to the requested channel.

Intended node: unfair AP.  It receives JSON or plain-text UDP requests from
unfair_beacon_channel_hunter.py and performs AP-driven CSA with hostapd_cli.

Example on the AP node:
  ./ap_channel_switch_server.py --bind 0.0.0.0 --port 4444 --iface wlan0

Plain UDP compatibility:
  echo 6 | nc -u -w 1 192.168.3.1 4444

JSON message example:
  {"type":"channel_switch","channel":6,"ssid":"tsiantos","bssid":"04:..."}
"""

import argparse
import json
import socket
import subprocess
import sys
import time


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def log(msg: str, err: bool = False) -> None:
    print("[%s] %s" % (now(), msg), file=(sys.stderr if err else sys.stdout), flush=True)


def channel_to_freq_mhz(value: int) -> int:
    """Accept 2.4GHz channel 1-14 or an already-specified MHz frequency."""
    if value > 1000:
        return value
    if value == 14:
        return 2484
    if 1 <= value <= 13:
        return 2407 + 5 * value
    raise ValueError(f"unsupported 2.4GHz channel/frequency: {value}")


def parse_request(data):
    text = data.decode("utf-8", "replace").strip()
    if not text:
        raise ValueError("empty UDP payload")

    # Backwards-compatible mode: hunter.py used `echo <channel> | nc -u ...`.
    if text.isdigit():
        return {"type": "channel_switch", "channel": int(text), "raw": text}

    try:
        obj = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"payload is neither integer channel nor JSON: {text!r}") from exc

    if not isinstance(obj, dict):
        raise ValueError("JSON payload must be an object")
    if obj.get("type", "channel_switch") != "channel_switch":
        raise ValueError(f"unsupported message type: {obj.get('type')!r}")
    if "channel" not in obj:
        # Accept direct CSA/SCA-shaped payloads too: {"new_channel":6},
        # {"target_channel":6}, or {"csa":{"channel":6,"ext_channel":6}}.
        csa_raw = obj.get("csa")
        csa_obj = csa_raw if isinstance(csa_raw, dict) else {}
        for key in ("new_channel", "target_channel"):
            if key in obj:
                obj["channel"] = obj[key]
                break
        else:
            for key in ("channel", "ext_channel"):
                if key in csa_obj and csa_obj[key] is not None:
                    obj["channel"] = csa_obj[key]
                    break
    if "channel" not in obj:
        raise ValueError("missing channel field")
    obj["channel"] = int(obj["channel"])
    return obj


def run_command(cmd, timeout):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, timeout=timeout)


class ChannelSwitchServer:
    def __init__(self, args):
        self.args = args
        self.last_channel = None
        self.last_switch_time = 0.0

    def hostapd_cli(self, *extra):
        cmd = ["hostapd_cli", "-p", self.args.ctrl_path, "-i", self.args.iface, *extra]
        return run_command(cmd, self.args.command_timeout)

    def switch_channel(self, channel_or_freq):
        freq = channel_to_freq_mhz(channel_or_freq)
        now_ts = time.time()
        if (
            self.last_channel == channel_or_freq
            and now_ts - self.last_switch_time < self.args.min_switch_interval
        ):
            log(f"suppress duplicate switch to {channel_or_freq}; min interval not elapsed")
            return True

        if self.args.dry_run:
            log(
                f"DRY-RUN would run: "
                f"hostapd_cli -p {self.args.ctrl_path} -i {self.args.iface} chan_switch {self.args.csa_count} {freq}"
            )
            self.last_channel = channel_or_freq
            self.last_switch_time = now_ts
            return True

        before = self.hostapd_cli("status")
        log(f"hostapd status before switch rc={before.returncode}\n{before.stdout.strip()}")

        result = self.hostapd_cli("chan_switch", str(self.args.csa_count), str(freq))
        log(
            f"chan_switch request channel={channel_or_freq} freq={freq} "
            f"rc={result.returncode}\n{result.stdout.strip()}"
        )
        if result.returncode != 0 or "FAIL" in result.stdout:
            return False

        time.sleep(self.args.post_switch_sleep)
        after = self.hostapd_cli("status")
        log(f"hostapd status after switch rc={after.returncode}\n{after.stdout.strip()}")

        self.last_channel = channel_or_freq
        self.last_switch_time = now_ts
        return True

    def handle_packet(self, data, addr):
        try:
            req = parse_request(data)
            if self.args.token and req.get("token") != self.args.token:
                raise ValueError("bad or missing token")
            channel = int(req["channel"])
            log(f"request from {addr[0]}:{addr[1]} bytes={len(data)}: {req}")
            ok = self.switch_channel(channel)
            log(f"request result: {'OK' if ok else 'FAILED'}")
        except Exception as exc:  # keep server alive for bad packets
            log(f"WARN: ignoring packet from {addr[0]}:{addr[1]}: {exc}", err=True)

    def run(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((self.args.bind, self.args.port))
        log(f"AP channel-switch server listening on {self.args.bind}:{self.args.port}")
        log(f"iface={self.args.iface} ctrl_path={self.args.ctrl_path} csa_count={self.args.csa_count}")
        status = self.hostapd_cli("status")
        log(f"initial hostapd status rc={status.returncode}\n{status.stdout.strip()}")
        try:
            while True:
                data, addr = sock.recvfrom(4096)
                self.handle_packet(data, addr)
        except KeyboardInterrupt:
            log("stopping AP channel-switch server")
            return 0


def build_arg_parser():
    p = argparse.ArgumentParser(description="Receive UDP channel-switch requests and run hostapd_cli chan_switch.")
    p.add_argument("--bind", default="0.0.0.0", help="UDP bind address")
    p.add_argument("--port", type=int, default=4444, help="UDP listen port")
    p.add_argument("--iface", default="wlan0", help="AP interface used by hostapd")
    p.add_argument("--ctrl-path", default="/var/run/hostapd", help="hostapd control interface directory")
    p.add_argument("--csa-count", type=int, default=5, help="CSA beacon count passed to hostapd_cli chan_switch")
    p.add_argument("--post-switch-sleep", type=float, default=2.0, help="seconds to wait before status-after logging")
    p.add_argument("--min-switch-interval", type=float, default=2.0, help="suppress duplicate switch requests within this many seconds")
    p.add_argument("--command-timeout", type=float, default=8.0, help="timeout for each hostapd_cli command")
    p.add_argument("--token", help="optional shared token required in JSON payloads")
    p.add_argument("--dry-run", action="store_true", help="log requested switch without running hostapd_cli")
    return p


def main():
    args = build_arg_parser().parse_args()
    if args.csa_count < 1:
        print("ERROR: --csa-count must be >= 1", file=sys.stderr)
        return 2
    return ChannelSwitchServer(args).run()


if __name__ == "__main__":
    raise SystemExit(main())
