#!/usr/bin/env python3
"""Listen for hostapd Channel Switch Announcement beacons and ask AP2 to follow.

Intended node: unfair STA/node.  The script keeps a monitor interface on a fixed
channel (normally the initial AP1/AP2 channel) and listens for beacon frames from
the fair/AP1 SSID/BSSID.  When a beacon carries Channel Switch Announcement
(CSA/SCA) information, it sends a UDP request to the unfair AP (AP2) asking it
to switch to the announced target channel.

This replaces the older channel-sweep behaviour.  It is faster and more precise
for hostapd_cli chan_switch because the AP advertises the new channel in beacon
IE 37/60 before the actual move.

Prerequisites on the unfair node:
  apt install python3-scapy -y
  iw dev wlan0 interface add mon1 type monitor
  ifconfig mon1 up

Example:
  ./unfair_beacon_channel_hunter.py \
      --monitor-iface mon1 \
      --listen-channel 1 \
      --ap-control-ip 192.168.3.1 \
      --target-ssid tsiantos \
      --ignore-ssid tsiantos_ap2

Optional: the script can also launch an iperf client while it listens:
  ./unfair_beacon_channel_hunter.py ... \
      --iperf-server-ip 192.168.3.1 --iperf-port 5003 \
      --iperf-rate 150M --iperf-duration 60
"""

import argparse
import json
import socket
import subprocess
import sys
import time
from typing import Iterable, Optional

try:
    from scapy.all import Dot11, Dot11Beacon, Dot11Elt, sniff  # type: ignore
    SCAPY_IMPORT_ERROR = None
except ImportError as exc:  # pragma: no cover - depends on node package state
    Dot11 = Dot11Beacon = Dot11Elt = sniff = None  # type: ignore
    SCAPY_IMPORT_ERROR = exc


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def log(msg: str, err: bool = False) -> None:
    print("[%s] %s" % (now(), msg), file=(sys.stderr if err else sys.stdout), flush=True)


def set_channel(iface: str, channel: int) -> bool:
    proc = subprocess.run(
        ["iw", "dev", iface, "set", "channel", str(channel)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )
    if proc.returncode != 0:
        log("WARN: failed to set %s to channel %s: %s" % (iface, channel, proc.stderr.strip()), err=True)
        return False
    return True


def dot11elt_iter(pkt) -> Iterable:
    elt = pkt.getlayer(Dot11Elt)
    while elt is not None:
        yield elt
        elt = elt.payload.getlayer(Dot11Elt)


def beacon_ssid(pkt) -> str:
    # Older Scapy versions on NITLab nodes do not support
    # pkt.getlayer(Dot11Elt, ID=0).  Walk Dot11Elt layers manually.
    for elt in dot11elt_iter(pkt):
        if getattr(elt, "ID", None) == 0:
            raw = bytes(getattr(elt, "info", b"") or b"")
            return raw.decode("utf-8", "ignore")
    return ""


def beacon_current_channel(pkt, fallback: int) -> int:
    """Return DS Parameter Set or HT Operation channel from beacon."""
    ds_channel = None
    ht_primary = None
    for elt in dot11elt_iter(pkt):
        eid = getattr(elt, "ID", None)
        data = bytes(getattr(elt, "info", b"") or b"")
        if eid == 3 and data:
            ch = int(data[0])
            if 1 <= ch <= 14:
                ds_channel = ch
        elif eid == 61 and data:
            ch = int(data[0])
            if 1 <= ch <= 14:
                ht_primary = ch
    return ds_channel or ht_primary or fallback


class CsaInfo:
    def __init__(self):
        self.channel = None          # type: Optional[int]
        self.count = None            # type: Optional[int]
        self.mode = None             # type: Optional[int]
        self.ext_channel = None      # type: Optional[int]
        self.ext_count = None        # type: Optional[int]
        self.ext_mode = None         # type: Optional[int]
        self.ext_op_class = None     # type: Optional[int]
        self.raw_csa = None          # type: Optional[str]
        self.raw_ext_csa = None      # type: Optional[str]

    def has_switch(self) -> bool:
        return self.channel is not None or self.ext_channel is not None

    def target_channel(self) -> Optional[int]:
        return self.channel if self.channel is not None else self.ext_channel

    def to_dict(self):
        return {
            "channel": self.channel,
            "count": self.count,
            "mode": self.mode,
            "ext_channel": self.ext_channel,
            "ext_count": self.ext_count,
            "ext_mode": self.ext_mode,
            "ext_op_class": self.ext_op_class,
            "raw_csa": self.raw_csa,
            "raw_ext_csa": self.raw_ext_csa,
        }


def parse_csa(pkt) -> CsaInfo:
    """Parse Channel Switch Announcement IE 37 and Extended CSA IE 60.

    IE 37 format: mode, new_channel, count.
    IE 60 format: mode, new_operating_class, new_channel, count.
    """
    csa = CsaInfo()
    for elt in dot11elt_iter(pkt):
        eid = getattr(elt, "ID", None)
        data = bytes(getattr(elt, "info", b"") or b"")
        if eid == 37:
            csa.raw_csa = data.hex()
            if len(data) >= 3:
                csa.mode = int(data[0])
                ch = int(data[1])
                csa.count = int(data[2])
                if 1 <= ch <= 14:
                    csa.channel = ch
        elif eid == 60:
            csa.raw_ext_csa = data.hex()
            if len(data) >= 4:
                csa.ext_mode = int(data[0])
                csa.ext_op_class = int(data[1])
                ch = int(data[2])
                csa.ext_count = int(data[3])
                if 1 <= ch <= 14:
                    csa.ext_channel = ch
    return csa


class CsaHit:
    def __init__(self, target_channel, current_channel, bssid, ssid, rssi, csa):
        self.target_channel = target_channel
        self.current_channel = current_channel
        self.bssid = bssid
        self.ssid = ssid
        self.rssi = rssi
        self.csa = csa


class CsaBeaconListener:
    def __init__(self, args: argparse.Namespace) -> None:
        assert Dot11 is not None and Dot11Beacon is not None and Dot11Elt is not None and sniff is not None
        self.args = args
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.last_notified_channel = None  # type: Optional[int]
        self.last_notification_time = 0.0
        self.iperf_proc = None             # type: Optional[subprocess.Popen]
        self.packet_count = 0
        self.beacon_count = 0
        self.target_beacon_count = 0
        self.csa_beacon_count = 0
        self.last_stats_time = time.time()
        self.logged_target_samples = 0

        self.target_bssid = args.target_bssid.lower() if args.target_bssid else None
        self.ignore_bssids = set([b.lower() for b in args.ignore_bssid])
        self.target_ssid = args.target_ssid
        self.ignore_ssids = set(args.ignore_ssid)

    def maybe_start_iperf(self) -> None:
        if not self.args.iperf_server_ip:
            return
        cmd = ["iperf", "-c", self.args.iperf_server_ip, "-p", str(self.args.iperf_port), "-t", str(self.args.iperf_duration), "-i", "1"]
        if self.args.iperf_udp:
            cmd.insert(3, "-u")
            cmd.extend(["-b", self.args.iperf_rate])
        log("starting iperf while listening: %s" % " ".join(cmd))
        self.iperf_proc = subprocess.Popen(cmd)

    def wait_iperf_if_needed(self) -> None:
        if self.iperf_proc is not None:
            rc = self.iperf_proc.wait()
            log("iperf finished rc=%s" % rc)

    def maybe_log_stats(self) -> None:
        now_ts = time.time()
        if self.args.stats_interval > 0 and now_ts - self.last_stats_time >= self.args.stats_interval:
            log(
                "stats packets=%s beacons=%s target_beacons=%s csa_beacons=%s last_notified_channel=%s"
                % (self.packet_count, self.beacon_count, self.target_beacon_count, self.csa_beacon_count, self.last_notified_channel)
            )
            self.last_stats_time = now_ts

    def packet_matches(self, pkt) -> Optional[CsaHit]:
        self.packet_count += 1
        self.maybe_log_stats()
        if not pkt.haslayer(Dot11Beacon):
            return None
        self.beacon_count += 1
        dot11 = pkt.getlayer(Dot11)
        bssid = (getattr(dot11, "addr2", None) or "").lower()
        if not bssid:
            return None
        ssid = beacon_ssid(pkt)

        if bssid in self.ignore_bssids:
            return None
        if ssid in self.ignore_ssids:
            return None
        if self.target_bssid and bssid != self.target_bssid:
            return None
        if self.target_ssid is not None and ssid != self.target_ssid:
            return None

        self.target_beacon_count += 1
        rssi = getattr(pkt, "dBm_AntSignal", None)
        current_channel = beacon_current_channel(pkt, self.args.listen_channel)
        csa = parse_csa(pkt)
        if self.logged_target_samples < self.args.target_beacon_samples:
            log(
                "target beacon sample ssid=%r bssid=%s current_channel=%s rssi=%s csa_present=%s csa=%s"
                % (ssid, bssid, current_channel, rssi, csa.has_switch(), csa.to_dict())
            )
            self.logged_target_samples += 1

        if not csa.has_switch():
            return None
        self.csa_beacon_count += 1
        target_channel = csa.target_channel()
        if target_channel is None:
            log("CSA beacon had no valid 2.4GHz target channel: ssid=%r bssid=%s csa=%s" % (ssid, bssid, csa.to_dict()), err=True)
            return None
        if target_channel == self.args.listen_channel and not self.args.notify_same_channel:
            log("CSA target equals listen channel %s; suppressing notification csa=%s" % (target_channel, csa.to_dict()))
            return None

        return CsaHit(target_channel=target_channel, current_channel=current_channel, bssid=bssid, ssid=ssid, rssi=rssi, csa=csa)

    def notify_ap(self, hit: CsaHit) -> None:
        now_ts = time.time()
        if (
            self.last_notified_channel == hit.target_channel
            and now_ts - self.last_notification_time < self.args.min_notify_interval
        ):
            return

        payload = {
            "type": "channel_switch",
            "channel": hit.target_channel,
            "current_channel": hit.current_channel,
            "bssid": hit.bssid,
            "ssid": hit.ssid,
            "rssi": hit.rssi,
            "csa": hit.csa.to_dict(),
            "seen_at": now(),
            "source": "unfair_beacon_channel_hunter.py",
        }
        if self.args.token:
            payload["token"] = self.args.token
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")

        if self.args.dry_run:
            log("DRY-RUN notify %s:%s: %s" % (self.args.ap_control_ip, self.args.ap_control_port, data.decode()))
        else:
            self.sock.sendto(data, (self.args.ap_control_ip, self.args.ap_control_port))
            log(
                "notified AP %s:%s to switch to channel %s after CSA beacon ssid=%r bssid=%s current_channel=%s csa=%s"
                % (self.args.ap_control_ip, self.args.ap_control_port, hit.target_channel, hit.ssid, hit.bssid, hit.current_channel, hit.csa.to_dict())
            )
        self.last_notified_channel = hit.target_channel
        self.last_notification_time = now_ts

    def run(self) -> None:
        if self.args.set_channel:
            if not set_channel(self.args.monitor_iface, self.args.listen_channel):
                log(
                    "WARN: continuing without forcing %s channel; this is expected when another active interface on the same phy controls the channel (STA/AP/iperf already running)"
                    % self.args.monitor_iface,
                    err=True,
                )
                if self.args.require_set_channel:
                    raise SystemExit(1)
        log("starting CSA beacon listener on %s fixed channel %s" % (self.args.monitor_iface, self.args.listen_channel))
        log("target_ssid=%r target_bssid=%r ignore_ssids=%r ignore_bssids=%r ap_control=%s:%s" % (self.target_ssid, self.target_bssid, list(self.ignore_ssids), list(self.ignore_bssids), self.args.ap_control_ip, self.args.ap_control_port))
        self.maybe_start_iperf()

        notified_once = [False]

        def handler(pkt) -> None:
            hit = self.packet_matches(pkt)
            if hit is None:
                return
            log(
                "CSA beacon: ssid=%r bssid=%s current_channel=%s target_channel=%s rssi=%s csa=%s"
                % (hit.ssid, hit.bssid, hit.current_channel, hit.target_channel, hit.rssi, hit.csa.to_dict())
            )
            self.notify_ap(hit)
            notified_once[0] = True

        try:
            sniff_fn = sniff
            assert sniff_fn is not None
            sniff_fn(
                iface=self.args.monitor_iface,
                prn=handler,
                timeout=self.args.timeout if self.args.timeout > 0 else None,
                store=False,
                stop_filter=(lambda _pkt: notified_once[0] and self.args.once),
            )
            self.wait_iperf_if_needed()
        except KeyboardInterrupt:
            log("stopping CSA beacon listener")
            if self.iperf_proc is not None and self.iperf_proc.poll() is None:
                self.iperf_proc.terminate()


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Listen on one fixed channel for CSA/SCA beacon frames and notify AP via UDP.")
    p.add_argument("--monitor-iface", default="mon1", help="monitor-mode interface used for Scapy sniffing")
    p.add_argument("--listen-channel", type=int, default=1, help="fixed channel to listen on for CSA beacons")
    p.add_argument("--set-channel", action="store_true", default=True, help="set monitor iface to --listen-channel before sniffing (default)")
    p.add_argument("--no-set-channel", action="store_false", dest="set_channel", help="do not change monitor iface channel")
    p.add_argument("--require-set-channel", action="store_true", help="exit if iw cannot force the monitor iface channel")
    p.add_argument("--ap-control-ip", required=True, help="Wi-Fi IP of the unfair AP running ap_channel_switch_server.py")
    p.add_argument("--ap-control-port", type=int, default=4444, help="UDP port of AP channel-switch server")
    # Backwards-compatible accepted args; no sweeping is performed anymore.
    p.add_argument("--channels", help=argparse.SUPPRESS)
    p.add_argument("--dwell-seconds", type=float, help=argparse.SUPPRESS)
    p.add_argument("--min-notify-interval", type=float, default=2.0, help="minimum seconds between repeated notifications for same channel")
    p.add_argument("--target-ssid", help="only react to this SSID; omit to react to any non-ignored CSA beacon")
    p.add_argument("--target-bssid", help="only react to this BSSID")
    p.add_argument("--ignore-ssid", action="append", default=[], help="SSID to ignore; may be repeated")
    p.add_argument("--ignore-bssid", action="append", default=[], help="BSSID to ignore; may be repeated")
    p.add_argument("--token", help="optional shared token included in UDP JSON payload")
    p.add_argument("--timeout", type=float, default=0.0, help="seconds to listen; 0 means forever")
    p.add_argument("--once", action="store_true", help="exit after first AP notification")
    p.add_argument("--notify-same-channel", action="store_true", help="notify even if CSA target equals listen channel")
    p.add_argument("--dry-run", action="store_true", help="print UDP messages instead of sending them")
    p.add_argument("--stats-interval", type=float, default=5.0, help="seconds between packet/beacon counter log lines; 0 disables")
    p.add_argument("--target-beacon-samples", type=int, default=10, help="number of matching target beacons to log even without CSA")

    p.add_argument("--iperf-server-ip", help="optional: start iperf client to this server while listening")
    p.add_argument("--iperf-port", type=int, default=5003, help="optional iperf client port")
    p.add_argument("--iperf-duration", type=int, default=60, help="optional iperf client duration")
    p.add_argument("--iperf-rate", default="150M", help="optional UDP iperf offered rate")
    p.add_argument("--iperf-udp", action="store_true", default=True, help="run optional iperf in UDP mode (default)")
    p.add_argument("--iperf-tcp", action="store_false", dest="iperf_udp", help="run optional iperf in TCP mode")
    return p


def main() -> int:
    args = build_arg_parser().parse_args()
    if args.listen_channel < 1 or args.listen_channel > 14:
        print("ERROR: --listen-channel must be a 2.4GHz channel 1-14", file=sys.stderr)
        return 2
    if args.timeout < 0:
        print("ERROR: --timeout must be >= 0", file=sys.stderr)
        return 2
    if args.min_notify_interval < 0:
        print("ERROR: --min-notify-interval must be >= 0", file=sys.stderr)
        return 2
    if args.stats_interval < 0 or args.target_beacon_samples < 0:
        print("ERROR: --stats-interval and --target-beacon-samples must be >= 0", file=sys.stderr)
        return 2
    if args.iperf_server_ip and args.iperf_duration <= 0:
        print("ERROR: --iperf-duration must be positive", file=sys.stderr)
        return 2
    if SCAPY_IMPORT_ERROR is not None:
        print("ERROR: scapy is not installed. Run: apt install python3-scapy -y", file=sys.stderr)
        return 2
    CsaBeaconListener(args).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
