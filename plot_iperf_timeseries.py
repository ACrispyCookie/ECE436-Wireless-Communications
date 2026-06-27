#!/usr/bin/env python3
"""Plot fair vs unfair iperf bandwidth over time from collected NITLab logs.

Expected collected layout from selfish_experiment.sh collect-logs:

  collected_logs/
    node069/<label>/node069_iperf_server_p5003.log
    node069/<label>/node069_iperf_server_p5004.log
    node084/<label>/node084_iperf_client_to_192.168.2.1_5M_60s.log
    node088/<label>/node088_iperf_client_to_192.168.2.1_150M_60s.log

For the fixed+sweep experiment we use receiver-side AP logs by default:
  unfair node088 fixed 150M -> AP server port 5003
  fair node084 sweep       -> AP server port 5004

If a receiver/server log is missing, the script falls back to the client log for that node.
"""

from __future__ import annotations

import argparse
import csv
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


BW_TO_MBIT = {
    "bits/sec": 1e-6,
    "Kbits/sec": 1e-3,
    "Mbits/sec": 1.0,
    "Gbits/sec": 1e3,
}

# iperf2 interval line examples:
# [  3]  0.0- 1.0 sec  1.79 MBytes  15.0 Mbits/sec  0.123 ms 0/1277 (0%)
# [  3]  0.0- 1.0 sec   640 KBytes  5.24 Mbits/sec
IPERF_LINE_RE = re.compile(
    r"\[\s*\d+\]\s+"
    r"(?P<t0>\d+(?:\.\d+)?)\s*-\s*(?P<t1>\d+(?:\.\d+)?)\s+sec\s+"
    r"(?P<transfer>[\d.]+)\s+(?P<transfer_unit>[KMG]?Bytes)\s+"
    r"(?P<bw>[\d.]+)\s+(?P<bw_unit>[KMG]?bits/sec)"
    r"(?:\s+(?P<jitter>[\d.]+)\s+ms\s+"
    r"(?P<lost>\d+)\s*/\s*(?P<total>\d+)\s*\((?P<loss_pct>[\d.]+)%\))?"
)


@dataclass
class Sample:
    t0: float
    t1: float
    bandwidth_mbps: float
    jitter_ms: float | None
    lost: int | None
    total: int | None
    loss_pct: float | None

    @property
    def t_mid(self) -> float:
        return (self.t0 + self.t1) / 2.0


def parse_iperf_timeseries(path: Path, include_summary: bool = False) -> list[Sample]:
    samples: list[Sample] = []
    for line in path.read_text(errors="replace").splitlines():
        m = IPERF_LINE_RE.search(line)
        if not m:
            continue
        t0 = float(m.group("t0"))
        t1 = float(m.group("t1"))
        # Default: skip final cumulative summary, keep per-second intervals.
        # Per-second logs usually have duration around 1s; summary spans much longer.
        if not include_summary and (t1 - t0) > 2.5:
            continue
        bw = float(m.group("bw")) * BW_TO_MBIT[m.group("bw_unit")]
        samples.append(
            Sample(
                t0=t0,
                t1=t1,
                bandwidth_mbps=bw,
                jitter_ms=float(m.group("jitter")) if m.group("jitter") else None,
                lost=int(m.group("lost")) if m.group("lost") else None,
                total=int(m.group("total")) if m.group("total") else None,
                loss_pct=float(m.group("loss_pct")) if m.group("loss_pct") else None,
            )
        )
    return samples


def label_dirs(log_root: Path) -> dict[str, list[Path]]:
    labels: dict[str, list[Path]] = {}
    for node_dir in sorted(p for p in log_root.iterdir() if p.is_dir()):
        for d in sorted(p for p in node_dir.iterdir() if p.is_dir()):
            labels.setdefault(d.name, []).append(d)
    return labels


def find_server_log(log_root: Path, ap_node: str, label: str, port: int) -> Path | None:
    candidates = sorted((log_root / ap_node / label).glob(f"*_iperf_server_p{port}.log"))
    return candidates[0] if candidates else None


def find_client_log(log_root: Path, node: str, label: str) -> Path | None:
    candidates = sorted((log_root / node / label).glob("*_iperf_client_*.log"))
    return candidates[0] if candidates else None


def pick_series(
    log_root: Path,
    label: str,
    ap_node: str,
    node: str,
    port: int | None,
    prefer_server: bool,
) -> tuple[Path | None, list[Sample], str]:
    paths: list[tuple[str, Path | None]] = []
    if prefer_server and port is not None:
        paths.append(("server", find_server_log(log_root, ap_node, label, port)))
    paths.append(("client", find_client_log(log_root, node, label)))
    if not prefer_server and port is not None:
        paths.append(("server", find_server_log(log_root, ap_node, label, port)))

    for source, path in paths:
        if path is None:
            continue
        samples = parse_iperf_timeseries(path)
        if samples:
            return path, samples, source
    return None, [], "missing"


def plot_label(
    label: str,
    fair: list[Sample],
    unfair: list[Sample],
    fair_desc: str,
    unfair_desc: str,
    out_png: Path,
) -> None:
    try:
        import matplotlib.pyplot as plt
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "Missing Python dependency: matplotlib\n"
            "Install it with one of:\n"
            "  python3 -m pip install matplotlib\n"
            "  sudo apt install python3-matplotlib\n"
        ) from exc

    plt.figure(figsize=(10, 5.5))
    if fair:
        plt.plot([s.t_mid for s in fair], [s.bandwidth_mbps for s in fair], marker="o", markersize=3, linewidth=1.5, label=fair_desc)
    if unfair:
        plt.plot([s.t_mid for s in unfair], [s.bandwidth_mbps for s in unfair], marker="s", markersize=3, linewidth=1.5, label=unfair_desc)
    plt.title(label.replace("_", " "))
    plt.xlabel("Time (s)")
    plt.ylabel("Bandwidth (Mbit/s)")
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()
    out_png.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(out_png, dpi=160)
    plt.close()


def write_summary_csv(rows: list[dict[str, str]], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = ["label", "series", "source", "log_file", "samples", "avg_mbps", "max_mbps", "plot"]
    with path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def avg(xs: Iterable[float]) -> float:
    vals = list(xs)
    return sum(vals) / len(vals) if vals else 0.0


def main() -> int:
    parser = argparse.ArgumentParser(description="Plot fair vs unfair iperf bandwidth time series per experiment label.")
    parser.add_argument("--logs", default="./selfish_collected_logs_fixed_sweep", help="Collected logs directory")
    parser.add_argument("--out", default=None, help="Output plot directory; default: <logs>/plots")
    parser.add_argument("--ap-node", default="node069", help="AP/server node directory name")
    parser.add_argument("--fair-node", default="node084", help="Fair/baseline node directory name")
    parser.add_argument("--unfair-node", default="node088", help="Unfair/modified node directory name")
    parser.add_argument("--fair-port", type=int, default=5004, help="AP server port corresponding to fair node")
    parser.add_argument("--unfair-port", type=int, default=5003, help="AP server port corresponding to unfair node")
    parser.add_argument("--client-only", action="store_true", help="Use client logs first instead of AP receiver/server logs")
    parser.add_argument("--label-filter", default="", help="Only plot labels containing this substring")
    args = parser.parse_args()

    log_root = Path(args.logs).expanduser().resolve()
    out_dir = Path(args.out).expanduser().resolve() if args.out else log_root / "plots"
    if not log_root.is_dir():
        raise SystemExit(f"Log directory not found: {log_root}")

    labels = label_dirs(log_root)
    if args.label_filter:
        labels = {k: v for k, v in labels.items() if args.label_filter in k}
    if not labels:
        raise SystemExit(f"No experiment label directories found under {log_root}")

    rows: list[dict[str, str]] = []
    for label in sorted(labels):
        fair_path, fair_samples, fair_source = pick_series(
            log_root, label, args.ap_node, args.fair_node, args.fair_port, prefer_server=not args.client_only
        )
        unfair_path, unfair_samples, unfair_source = pick_series(
            log_root, label, args.ap_node, args.unfair_node, args.unfair_port, prefer_server=not args.client_only
        )
        if not fair_samples and not unfair_samples:
            continue

        out_png = out_dir / f"{label}_bandwidth_timeseries.png"
        fair_desc = f"fair {args.fair_node} ({fair_source}, port {args.fair_port})"
        unfair_desc = f"unfair {args.unfair_node} ({unfair_source}, port {args.unfair_port})"
        plot_label(label, fair_samples, unfair_samples, fair_desc, unfair_desc, out_png)

        for series, source, path, samples in [
            ("fair", fair_source, fair_path, fair_samples),
            ("unfair", unfair_source, unfair_path, unfair_samples),
        ]:
            rows.append(
                {
                    "label": label,
                    "series": series,
                    "source": source,
                    "log_file": str(path.relative_to(log_root)) if path else "",
                    "samples": str(len(samples)),
                    "avg_mbps": f"{avg(s.bandwidth_mbps for s in samples):.3f}" if samples else "",
                    "max_mbps": f"{max((s.bandwidth_mbps for s in samples), default=0.0):.3f}" if samples else "",
                    "plot": str(out_png),
                }
            )
        print(f"Wrote {out_png}")

    summary = out_dir / "plot_summary.csv"
    write_summary_csv(rows, summary)
    print(f"Wrote {summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
