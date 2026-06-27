#!/usr/bin/env bash
set -euo pipefail

# Selfish-mode ath9k experiment helper for NITLab.
# Run from your local PC/workspace. It talks to nitlab3, then to the reserved nodes.
# Default topology:
#   AP   node069 -> 192.168.2.1, baseline ath9k
#   STA1 node084 -> 192.168.2.2, baseline ath9k
#   STA2 node088 -> 192.168.2.3, modified ath9k_hw loaded with selfish_mode=1
#
# Examples:
#   ./selfish_experiment.sh make-patch
#   ./selfish_experiment.sh load-image --nodes node069,node084,node088
#   ./selfish_experiment.sh apply-patch --nodes node088
#   ./selfish_experiment.sh build --nodes node088
#   ./selfish_experiment.sh load-driver --node node069 --selfish 0
#   ./selfish_experiment.sh load-driver --node node084 --selfish 0
#   ./selfish_experiment.sh load-driver --node node088 --selfish 1
#   ./selfish_experiment.sh start-ap --node node069
#   ./selfish_experiment.sh connect-sta --node node084 --ip 192.168.2.2
#   ./selfish_experiment.sh connect-sta --node node088 --ip 192.168.2.3
#   ./selfish_experiment.sh run-iperf --server node084 --client node069 --server-ip 192.168.2.2 --rate 15M --duration 60 --label ap_to_sta1_15M
#   ./selfish_experiment.sh run-iperf --server node088 --client node069 --server-ip 192.168.2.3 --rate 15M --duration 60 --label ap_to_sta2_selfish_15M
#   ./selfish_experiment.sh collect-logs --nodes node069,node084,node088 --out ./selfish_collected_logs

GATEWAY="${GATEWAY:-dtsiantos@nitlab3.inf.uth.gr}"
IMAGE="${IMAGE:-baseline_wireless_communications.ndz}"
NODES="${NODES:-node069,node084,node088}"
BACKPORTS_DIR="${BACKPORTS_DIR:-/root/backports-5.4.56-1}"
LOG_DIR="${LOG_DIR:-/root/selfish_exp_logs}"
SSID="${SSID:-tsiantos}"
CHANNEL="${CHANNEL:-7}"
AP_IP="${AP_IP:-192.168.2.1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${PATCH_FILE:-$SCRIPT_DIR/selfish_mode_ath9k.patch}"
SRC_REPO="${SRC_REPO:-$SCRIPT_DIR}"
BASE_REF="${BASE_REF:-origin/baseline}"
MOD_REF="${MOD_REF:-main}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no)

usage() {
  sed -n '1,42p' "$0" >&2
  cat >&2 <<'EOF'

Commands:
  make-patch
      Create patch from SRC_REPO diff BASE_REF..MOD_REF.

  load-image --nodes n1,n2,...
      Load baseline image on selected nodes via omf.

  apply-patch --nodes n1,n2,... [--patch file]
      Copy patch to gateway and nodes, then apply it in BACKPORTS_DIR.
      Idempotent: if the patch is already applied, it does not re-apply.

  build --nodes n1,n2,...
      On each node: make defconfig-ath9k && make -j$(nproc), unload old stack,
      make install, depmod -a. Does NOT automatically load the driver.

  load-driver --node n [--selfish 0|1]
      Unload ath9k stack, modprobe ath9k_hw selfish_mode=<0|1>, then modprobe ath9k.
      Also prints /sys/module/ath9k_hw/parameters/selfish_mode when available.
      This is how STA2 gets selfish_mode: modprobe ath9k_hw selfish_mode=1.

  start-ap --node n [--ip 192.168.2.1]
      Configure wlan0 and start hostapd in background with logs.

  connect-sta --node n --ip 192.168.2.X
      Configure wlan0, connect to SSID, and save link/ping evidence.

  iperf-server --node n [--port 5003] [--label label]
      Start UDP iperf server in background on node.

  iperf-client --node n --server-ip IP [--rate 15M] [--duration 60] [--port 5003] [--label label]
      Run UDP iperf client in foreground on node, logging locally on node.

  run-iperf --server n --client n --server-ip IP [--rate 15M] [--duration 60] [--port 5003] [--label label]
      Start server, then run client.

  run-dual-sweep --server AP --server-ip IP --client-a STA1 --client-b STA2 [--rates 5M,10M,15M] [--duration 60] [--port 5003] [--prefix label]
      For each rate, start one AP-side UDP server and run both STA clients concurrently.
      Labels include timestamp/prefix and rate, so sweep logs do not overwrite each other.

  run-fixed-sweep --server AP --server-ip IP --fixed-client node088 --fixed-rate 150M --sweep-client node086 [--rates 5M,25M,50M,150M] [--duration 60] [--fixed-port 5003] [--sweep-port 5004] [--prefix label]
      For each sweep rate, keep fixed-client transmitting at fixed-rate while sweep-client varies rate.
      Uses separate UDP server ports/logs for fixed and sweep clients so parsing is unambiguous.

  collect-logs --nodes n1,n2,... [--out dir]
      Tar logs on nodes, copy to gateway, then copy from gateway to local PC.

  parse-logs --in dir [--out csv]
      Parse collected iperf logs into CSV. Uses receiver/server summaries when available.

  status --nodes n1,n2,...
      Print module parameters, iw link/dev, ip addr, and recent dmesg snippets.

Environment overrides:
  GATEWAY, IMAGE, NODES, BACKPORTS_DIR, LOG_DIR, SSID, CHANNEL, AP_IP,
  PATCH_FILE, SRC_REPO, BASE_REF, MOD_REF
EOF
}

split_nodes() { tr ',' ' ' <<<"$1"; }

gw() {
  ssh "${SSH_OPTS[@]}" "$GATEWAY" "$@"
}

node_ssh() {
  local node="$1"; shift
  gw "ssh -o StrictHostKeyChecking=no root@${node} $(printf '%q ' "$@")"
}

node_bash() {
  local node="$1" script="$2"
  gw "ssh -o StrictHostKeyChecking=no root@${node} 'bash -s'" <<<"$script"
}

need_patch() {
  if [[ ! -f "$PATCH_FILE" ]]; then
    echo "Patch file not found: $PATCH_FILE" >&2
    echo "Run: $0 make-patch" >&2
    exit 1
  fi
}

cmd_make_patch() {
  if [[ ! -d "$SRC_REPO/.git" ]]; then
    echo "SRC_REPO is not a git repo: $SRC_REPO" >&2
    exit 1
  fi
  git -C "$SRC_REPO" diff --binary --relative=backports-5.4.56-1 "$BASE_REF" -- \
    backports-5.4.56-1/drivers/net/wireless/ath/ath9k/init.c \
    backports-5.4.56-1/drivers/net/wireless/ath/ath9k/mac.c \
    > "$PATCH_FILE"
  if [[ ! -s "$PATCH_FILE" ]]; then
    echo "Patch is empty; check BASE_REF=$BASE_REF and local working-tree changes" >&2
    exit 1
  fi
  echo "Created patch: $PATCH_FILE"
  grep -n "selfish_mode\|module_param" "$PATCH_FILE" || true
}

cmd_load_image() {
  local nodes="$NODES"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --nodes) nodes="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done

  echo "[setup] loading $IMAGE on nodes: $nodes"
  echo "[setup] Do not press Ctrl-C while OMF is loading the image; an interrupted load can leave a node half-imaged/PXE-only."
  # Load all selected nodes in one OMF call instead of looping node-by-node. This keeps the
  # reservation topology consistent and avoids continuing to the next node after an interrupted load.
  gw "omf load -i '$IMAGE' -t '$nodes'"

  echo "[setup] OMF load command finished. Waiting for nodes to accept SSH..."
  local attempts
  attempts="$(seq 1 60 | tr '\n' ' ')"
  for n in $(split_nodes "$nodes"); do
    echo "[setup] waiting for root@$n ssh"
    gw "for i in $attempts; do ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@'$n' 'hostname' >/dev/null 2>&1 && exit 0; sleep 5; done; echo 'WARNING: root@$n did not become SSH-ready within 5 minutes' >&2; exit 0"
  done
}

cmd_apply_patch() {
  local nodes="$NODES" patch="$PATCH_FILE"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --nodes) nodes="$2"; shift 2;;
      --patch) patch="$2"; PATCH_FILE="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done
  need_patch
  local remote_patch="/tmp/$(basename "$patch")"
  echo "[copy] $patch -> $GATEWAY:$remote_patch"
  scp "${SSH_OPTS[@]}" "$patch" "$GATEWAY:$remote_patch"
  for n in $(split_nodes "$nodes"); do
    echo "[patch] $n"
    gw "scp '$remote_patch' root@'$n':'$remote_patch'"
    node_bash "$n" "
set -euo pipefail
cd '$BACKPORTS_DIR'
if [[ ! -f drivers/net/wireless/ath/ath9k/init.c || ! -f drivers/net/wireless/ath/ath9k/mac.c ]]; then
  echo 'Wrong BACKPORTS_DIR: $BACKPORTS_DIR' >&2
  exit 1
fi
if grep -q 'module_param(selfish_mode' drivers/net/wireless/ath/ath9k/mac.c; then
  echo 'selfish_mode already present in ath9k_hw/mac.c; skipping apply'
else
  if grep -q 'module_param(selfish_mode' drivers/net/wireless/ath/ath9k/init.c && grep -q 'extern bool selfish_mode' drivers/net/wireless/ath/ath9k/mac.c; then
    echo 'detected old broken selfish_mode layout; moving module parameter from ath9k/init.c to ath9k_hw/mac.c'
    sed -i '/SELFISH MODE/,+6d' drivers/net/wireless/ath/ath9k/init.c
    grep -q 'linux/moduleparam.h' drivers/net/wireless/ath/ath9k/mac.c || \
      sed -i '/#include <linux\/export.h>/a #include <linux/moduleparam.h>' drivers/net/wireless/ath/ath9k/mac.c
    sed -i '/extern bool selfish_mode;/c\\bool selfish_mode = false;\
module_param(selfish_mode, bool, 0644);' drivers/net/wireless/ath/ath9k/mac.c
  else
    if command -v git >/dev/null 2>&1; then
      git apply --check '$remote_patch'
      git apply '$remote_patch'
    else
      patch -p1 < '$remote_patch'
    fi
  fi
fi
grep -n 'selfish_mode\|MODULE_PARM_DESC(selfish_mode' drivers/net/wireless/ath/ath9k/init.c drivers/net/wireless/ath/ath9k/mac.c || true
"
  done
}

cmd_build() {
  local nodes="$NODES"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --nodes) nodes="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done
  for n in $(split_nodes "$nodes"); do
    echo "[build] $n"
    node_bash "$n" "
set -euo pipefail
cd '$BACKPORTS_DIR'
make defconfig-ath9k
make -j\$(nproc)
killall hostapd 2>/dev/null || true
ip link set wlan0 down 2>/dev/null || true
modprobe -r ath9k ath9k_common ath9k_hw ath mac80211 cfg80211 2>/dev/null || true
make install
depmod -a
echo build/install done on \$(hostname)
"
  done
}

cmd_load_driver() {
  local node="" selfish="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node) node="$2"; shift 2;;
      --selfish) selfish="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done
  [[ -n "$node" ]] || { echo "--node required" >&2; exit 1; }
  echo "[load-driver] $node selfish_mode=$selfish"
  node_bash "$node" "
set -euo pipefail
mkdir -p '$LOG_DIR'
killall hostapd 2>/dev/null || true
ip link set wlan0 down 2>/dev/null || true
modprobe -r ath9k ath9k_common ath9k_hw ath mac80211 cfg80211 2>/dev/null || true
modprobe ath9k_hw selfish_mode=$selfish
modprobe ath9k
{
  date
  echo 'modprobe ath9k_hw selfish_mode=$selfish; modprobe ath9k'
  modinfo ath9k | head -40 || true
  if [[ -f /sys/module/ath9k_hw/parameters/selfish_mode ]]; then
    echo -n 'selfish_mode='; cat /sys/module/ath9k_hw/parameters/selfish_mode
  else
    echo 'WARNING: /sys/module/ath9k_hw/parameters/selfish_mode missing; modified ath9k_hw module may not be installed/loaded'
  fi
  lsmod | grep ath9k || true
  dmesg | tail -80 || true
} | tee '$LOG_DIR/${node}_load_driver_selfish_${selfish}.log'
"
}

cmd_start_ap() {
  local node="" ip="$AP_IP"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node) node="$2"; shift 2;;
      --ip) ip="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done
  [[ -n "$node" ]] || { echo "--node required" >&2; exit 1; }
  echo "[start-ap] $node ip=$ip ssid=$SSID channel=$CHANNEL"
  node_bash "$node" "
set -euo pipefail
mkdir -p '$LOG_DIR'
if ! command -v hostapd >/dev/null 2>&1; then
  echo '[start-ap] hostapd not found; installing with apt...'
  export DEBIAN_FRONTEND=noninteractive
  apt install -y hostapd
fi
cat > /root/selfish_ap.conf <<'EOF'
interface=wlan0
driver=nl80211
ssid=$SSID
hw_mode=g
channel=$CHANNEL
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
EOF
ip link set wlan0 down 2>/dev/null || true
ifconfig wlan0 '$ip' up
killall hostapd 2>/dev/null || true
nohup hostapd -dd /root/selfish_ap.conf > '$LOG_DIR/${node}_hostapd.log' 2>&1 & echo \
\$! > '$LOG_DIR/${node}_hostapd.pid'
sleep 2
cat '$LOG_DIR/${node}_hostapd.pid'
tail -40 '$LOG_DIR/${node}_hostapd.log' || true
"
}

cmd_connect_sta() {
  local node="" ip=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node) node="$2"; shift 2;;
      --ip) ip="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done
  [[ -n "$node" && -n "$ip" ]] || { echo "--node and --ip required" >&2; exit 1; }
  echo "[connect-sta] $node ip=$ip ssid=$SSID"
  node_bash "$node" "
set -euo pipefail
mkdir -p '$LOG_DIR'
ip link set wlan0 down 2>/dev/null || true
ifconfig wlan0 '$ip' up
iw dev wlan0 disconnect 2>/dev/null || true
iw dev wlan0 connect '$SSID' || true
sleep 3
{
  date
  ip addr show wlan0
  iw dev wlan0 link || true
  ping -c 5 '$AP_IP' || true
} | tee '$LOG_DIR/${node}_sta_connect.log'
"
}

cmd_iperf_server() {
  local node="" port="5003" label="server_$(date +%Y%m%d_%H%M%S)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node) node="$2"; shift 2;;
      --port) port="$2"; shift 2;;
      --label) label="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done
  [[ -n "$node" ]] || { echo "--node required" >&2; exit 1; }
  node_bash "$node" "
set -euo pipefail
mkdir -p '$LOG_DIR/$label'
if ! command -v iperf >/dev/null 2>&1; then
  echo '[iperf-server] iperf not found; installing with apt...'
  export DEBIAN_FRONTEND=noninteractive
  apt install -y iperf
fi
if [[ -f '$LOG_DIR/iperf_server_${port}.pid' ]]; then
  old_pid=\$(cat '$LOG_DIR/iperf_server_${port}.pid' 2>/dev/null || true)
  if [[ -n "\${old_pid:-}" ]]; then
    kill "\$old_pid" 2>/dev/null || true
  fi
fi
nohup iperf -s -u -p '$port' -i 1 > '$LOG_DIR/$label/${node}_iperf_server_p${port}.log' 2>&1 & echo \$! > '$LOG_DIR/iperf_server_${port}.pid'
sleep 1
cat '$LOG_DIR/iperf_server_${port}.pid'
tail -5 '$LOG_DIR/$label/${node}_iperf_server_p${port}.log' || true
"
}

cmd_iperf_client() {
  local node="" server_ip="" rate="15M" duration="60" port="5003" label="client_$(date +%Y%m%d_%H%M%S)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node) node="$2"; shift 2;;
      --server-ip) server_ip="$2"; shift 2;;
      --rate) rate="$2"; shift 2;;
      --duration) duration="$2"; shift 2;;
      --port) port="$2"; shift 2;;
      --label) label="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done
  [[ -n "$node" && -n "$server_ip" ]] || { echo "--node and --server-ip required" >&2; exit 1; }
  node_bash "$node" "
set -euo pipefail
mkdir -p '$LOG_DIR/$label'
if ! command -v iperf >/dev/null 2>&1; then
  echo '[iperf-client] iperf not found; installing with apt...'
  export DEBIAN_FRONTEND=noninteractive
  apt install -y iperf
fi
{
  date
  echo 'iperf -c $server_ip -u -p $port -b $rate -t $duration -i 1'
  iperf -c '$server_ip' -u -p '$port' -b '$rate' -t '$duration' -i 1
} 2>&1 | tee '$LOG_DIR/$label/${node}_iperf_client_to_${server_ip}_${rate}_${duration}s.log'
"
}

cmd_run_iperf() {
  local server="" client="" server_ip="" rate="15M" duration="60" port="5003" label="run_$(date +%Y%m%d_%H%M%S)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server) server="$2"; shift 2;;
      --client) client="$2"; shift 2;;
      --server-ip) server_ip="$2"; shift 2;;
      --rate) rate="$2"; shift 2;;
      --duration) duration="$2"; shift 2;;
      --port) port="$2"; shift 2;;
      --label) label="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done
  [[ -n "$server" && -n "$client" && -n "$server_ip" ]] || { echo "--server --client --server-ip required" >&2; exit 1; }
  cmd_iperf_server --node "$server" --port "$port" --label "$label"
  sleep 2
  cmd_iperf_client --node "$client" --server-ip "$server_ip" --rate "$rate" --duration "$duration" --port "$port" --label "$label"
}

cmd_run_dual_sweep() {
  local server="node069" server_ip="$AP_IP" client_a="node084" client_b="node088" rates="5M,10M,15M,20M,25M" duration="60" port="5003" prefix="dual_sweep_$(date +%Y%m%d_%H%M%S)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server) server="$2"; shift 2;;
      --server-ip) server_ip="$2"; shift 2;;
      --client-a) client_a="$2"; shift 2;;
      --client-b) client_b="$2"; shift 2;;
      --rates) rates="$2"; shift 2;;
      --duration) duration="$2"; shift 2;;
      --port) port="$2"; shift 2;;
      --prefix) prefix="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done
  [[ -n "$server" && -n "$server_ip" && -n "$client_a" && -n "$client_b" ]] || { echo "--server --server-ip --client-a --client-b required" >&2; exit 1; }
  for rate in $(tr ',' ' ' <<<"$rates"); do
    local safe_rate label
    safe_rate="${rate//[^A-Za-z0-9_.-]/_}"
    label="${prefix}_${safe_rate}_per_sta"
    echo "[dual-sweep] rate=$rate duration=${duration}s label=$label"
    cmd_iperf_server --node "$server" --port "$port" --label "$label"
    sleep 2
    cmd_iperf_client --node "$client_a" --server-ip "$server_ip" --rate "$rate" --duration "$duration" --port "$port" --label "$label" &
    local pid_a=$!
    cmd_iperf_client --node "$client_b" --server-ip "$server_ip" --rate "$rate" --duration "$duration" --port "$port" --label "$label" &
    local pid_b=$!
    local rc_a=0 rc_b=0
    wait "$pid_a" || rc_a=$?
    wait "$pid_b" || rc_b=$?
    if [[ "$rc_a" -ne 0 || "$rc_b" -ne 0 ]]; then
      echo "[dual-sweep] ERROR: clients failed for rate=$rate: $client_a rc=$rc_a, $client_b rc=$rc_b" >&2
      return 1
    fi
    sleep 2
  done
}

cmd_run_fixed_sweep() {
  local server="node069" server_ip="$AP_IP" fixed_client="node088" fixed_rate="150M" sweep_client="node086" rates="5M,25M,50M,150M" duration="60" fixed_port="5003" sweep_port="5004" prefix="fixed150_sweep_$(date +%Y%m%d_%H%M%S)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server) server="$2"; shift 2;;
      --server-ip) server_ip="$2"; shift 2;;
      --fixed-client) fixed_client="$2"; shift 2;;
      --fixed-rate) fixed_rate="$2"; shift 2;;
      --sweep-client) sweep_client="$2"; shift 2;;
      --rates) rates="$2"; shift 2;;
      --duration) duration="$2"; shift 2;;
      --fixed-port) fixed_port="$2"; shift 2;;
      --sweep-port) sweep_port="$2"; shift 2;;
      --prefix) prefix="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done
  [[ -n "$server" && -n "$server_ip" && -n "$fixed_client" && -n "$sweep_client" ]] || { echo "--server --server-ip --fixed-client --sweep-client required" >&2; exit 1; }
  if [[ "$fixed_port" == "$sweep_port" ]]; then
    echo "--fixed-port and --sweep-port must differ so server logs are parseable per client" >&2
    exit 1
  fi
  for sweep_rate in $(tr ',' ' ' <<<"$rates"); do
    local safe_fixed safe_sweep label
    safe_fixed="${fixed_rate//[^A-Za-z0-9_.-]/_}"
    safe_sweep="${sweep_rate//[^A-Za-z0-9_.-]/_}"
    label="${prefix}_fixed_${fixed_client}_${safe_fixed}_sweep_${sweep_client}_${safe_sweep}"
    echo "[fixed-sweep] fixed ${fixed_client}=${fixed_rate} on port ${fixed_port}; sweep ${sweep_client}=${sweep_rate} on port ${sweep_port}; duration=${duration}s; label=$label"
    cmd_iperf_server --node "$server" --port "$fixed_port" --label "$label"
    cmd_iperf_server --node "$server" --port "$sweep_port" --label "$label"
    sleep 2
    cmd_iperf_client --node "$fixed_client" --server-ip "$server_ip" --rate "$fixed_rate" --duration "$duration" --port "$fixed_port" --label "$label" &
    local pid_fixed=$!
    cmd_iperf_client --node "$sweep_client" --server-ip "$server_ip" --rate "$sweep_rate" --duration "$duration" --port "$sweep_port" --label "$label" &
    local pid_sweep=$!
    local rc_fixed=0 rc_sweep=0
    wait "$pid_fixed" || rc_fixed=$?
    wait "$pid_sweep" || rc_sweep=$?
    if [[ "$rc_fixed" -ne 0 || "$rc_sweep" -ne 0 ]]; then
      echo "[fixed-sweep] ERROR: clients failed for sweep_rate=$sweep_rate: $fixed_client rc=$rc_fixed, $sweep_client rc=$rc_sweep" >&2
      return 1
    fi
    sleep 2
  done
}

cmd_parse_logs() {
  local indir="./selfish_collected_logs" out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --in) indir="$2"; shift 2;;
      --out) out="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done
  [[ -d "$indir" ]] || { echo "Input log directory not found: $indir" >&2; exit 1; }
  if [[ -z "$out" ]]; then
    out="$indir/iperf_summary.csv"
  fi
  python3 - "$indir" "$out" <<'PY'
import csv, re, sys
from pathlib import Path
indir = Path(sys.argv[1])
out = Path(sys.argv[2])
# Matches common iperf2 summary lines, e.g.:
# [  3]  0.0-60.0 sec  105 MBytes  14.7 Mbits/sec  0.123 ms  1/1000 (0.1%)
bw_re = re.compile(r'\[\s*\d+\]\s+(?P<interval>\d+(?:\.\d+)?\s*-\s*\d+(?:\.\d+)?)\s+sec\s+(?P<transfer>[\d.]+)\s+(?P<transfer_unit>[KMG]?Bytes)\s+(?P<bw>[\d.]+)\s+(?P<bw_unit>[KMG]?bits/sec)(?:\s+(?P<jitter>[\d.]+)\s+ms\s+(?P<lost>\d+)\s*/\s*(?P<total>\d+)\s*\((?P<loss_pct>[\d.]+)%\))?')
client_cmd_re = re.compile(r'iperf\s+-c\s+(?P<server_ip>\S+).*?-p\s+(?P<port>\d+).*?-b\s+(?P<rate>\S+).*?-t\s+(?P<duration>\S+)')
rows=[]
for f in sorted(indir.rglob('*iperf*log')):
    text=f.read_text(errors='replace')
    lines=[ln.strip() for ln in text.splitlines() if ln.strip()]
    matches=[]
    for ln in lines:
        m=bw_re.search(ln)
        if m:
            matches.append((ln,m))
    if not matches:
        continue
    ln,m=matches[-1]
    rel=f.relative_to(indir)
    parts=rel.parts
    node=parts[0] if len(parts)>0 else ''
    label=parts[1] if len(parts)>2 else (parts[-2] if len(parts)>1 else '')
    name=f.name
    role='server' if '_iperf_server_' in name else 'client' if '_iperf_client_' in name else 'unknown'
    port=''
    pm=re.search(r'_p(\d+)\.log$', name)
    if pm: port=pm.group(1)
    offered_rate=''
    duration=''
    server_ip=''
    for l2 in lines:
        cm=client_cmd_re.search(l2)
        if cm:
            server_ip=cm.group('server_ip'); port=cm.group('port'); offered_rate=cm.group('rate'); duration=cm.group('duration')
            break
    lost=m.group('lost') or ''
    total=m.group('total') or ''
    loss_pct=m.group('loss_pct') or ''
    rows.append({
        'label': label, 'node': node, 'role': role, 'port': port, 'offered_rate': offered_rate,
        'duration_s': duration, 'server_ip': server_ip, 'interval_s': m.group('interval').replace(' ', ''),
        'transfer': m.group('transfer'), 'transfer_unit': m.group('transfer_unit'),
        'bandwidth': m.group('bw'), 'bandwidth_unit': m.group('bw_unit'),
        'jitter_ms': m.group('jitter') or '', 'lost': lost, 'total': total, 'loss_pct': loss_pct,
        'source_file': str(rel), 'summary_line': ln,
    })
out.parent.mkdir(parents=True, exist_ok=True)
fields=['label','node','role','port','offered_rate','duration_s','server_ip','interval_s','transfer','transfer_unit','bandwidth','bandwidth_unit','jitter_ms','lost','total','loss_pct','source_file','summary_line']
with out.open('w', newline='') as fh:
    w=csv.DictWriter(fh, fieldnames=fields)
    w.writeheader(); w.writerows(rows)
print(f'Wrote {len(rows)} rows to {out}')
# Also print compact receiver-side table for quick Discord/terminal inspection.
print('Receiver/server rows:')
for r in rows:
    if r['role'] == 'server':
        print(f"{r['label']} {r['node']} port={r['port']} bw={r['bandwidth']} {r['bandwidth_unit']} loss={r['lost']}/{r['total']} ({r['loss_pct']}%) jitter={r['jitter_ms']}ms")
PY
}

cmd_collect_logs() {
  local nodes="$NODES" out="./selfish_collected_logs"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --nodes) nodes="$2"; shift 2;;
      --out) out="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done
  mkdir -p "$out"
  local stamp="$(date +%Y%m%d_%H%M%S)"
  for n in $(split_nodes "$nodes"); do
    echo "[collect] $n"
    node_bash "$n" "
set -euo pipefail
if [[ -d '$LOG_DIR' ]]; then
  tar czf '/tmp/${n}_selfish_logs_${stamp}.tar.gz' -C '$LOG_DIR' .
else
  echo 'No LOG_DIR: $LOG_DIR' >&2
  mkdir -p /tmp/empty_logs
  tar czf '/tmp/${n}_selfish_logs_${stamp}.tar.gz' -C /tmp/empty_logs .
fi
"
    gw "scp root@'$n':'/tmp/${n}_selfish_logs_${stamp}.tar.gz' '/tmp/${n}_selfish_logs_${stamp}.tar.gz'"
    scp "${SSH_OPTS[@]}" "$GATEWAY:/tmp/${n}_selfish_logs_${stamp}.tar.gz" "$out/"
    mkdir -p "$out/$n"
    tar xzf "$out/${n}_selfish_logs_${stamp}.tar.gz" -C "$out/$n"
  done
  echo "Collected logs under: $out"
}

cmd_status() {
  local nodes="$NODES"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --nodes) nodes="$2"; shift 2;;
      *) usage; exit 1;;
    esac
  done
  for n in $(split_nodes "$nodes"); do
    echo "===== $n ====="
    node_bash "$n" "
set +e
hostname
date
lsmod | grep ath9k
if [[ -f /sys/module/ath9k_hw/parameters/selfish_mode ]]; then echo -n 'selfish_mode='; cat /sys/module/ath9k_hw/parameters/selfish_mode; fi
ip addr show wlan0
iw dev wlan0 link
iw dev
dmesg | grep -i 'ath9k\|selfish\|CWmin' | tail -40
"
  done
}


prompt_default() {
  local prompt="$1" default="$2" value
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "$prompt: " value
    printf '%s' "$value"
  fi
}

prompt_required() {
  local prompt="$1" value
  while true; do
    read -r -p "$prompt: " value
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    echo "Value required."
  done
}

run_menu_action() {
  local title="$1"; shift
  echo
  echo "==> $title"
  if "$@"; then
    echo "==> Done: $title"
  else
    local rc=$?
    echo "==> FAILED ($rc): $title" >&2
    echo "Returning to menu." >&2
  fi
  echo
  read -r -p "Press Enter to continue..." _
}

interactive_menu() {
  while true; do
    clear 2>/dev/null || true
    cat <<EOF
Selfish ath9k NITLab CLI
========================
Gateway:       $GATEWAY
Default nodes: $NODES
SSID/channel:  $SSID / $CHANNEL
AP IP:         $AP_IP
Backports dir: $BACKPORTS_DIR
Patch file:    $PATCH_FILE

1)  setup nodes / load baseline image
2)  make patch from local repo
3)  apply patch to selected nodes
4)  build/install backports on selected nodes
5)  load driver on one node (selfish_mode 0/1)
6)  start AP on one node
7)  connect STA on one node
8)  run iperf server on one node
9)  run iperf client on one node
10) run iperf server+client
11) run dual-client rate sweep
12) run fixed+selfish-vs-sweep experiment
13) collect logs from selected nodes
14) parse collected iperf logs
15) status/debug selected nodes
16) edit defaults for this session
h)  help
q)  quit
EOF
    echo
    read -r -p "Select option: " choice
    case "$choice" in
      1)
        local nodes
        nodes=$(prompt_default "Nodes to setup/load image" "$NODES")
        run_menu_action "setup nodes: $nodes" cmd_load_image --nodes "$nodes"
        ;;
      2)
        run_menu_action "make patch" cmd_make_patch
        ;;
      3)
        local nodes patch
        nodes=$(prompt_default "Nodes to patch" "node088")
        patch=$(prompt_default "Patch file" "$PATCH_FILE")
        run_menu_action "apply patch to: $nodes" cmd_apply_patch --nodes "$nodes" --patch "$patch"
        ;;
      4)
        local nodes
        nodes=$(prompt_default "Nodes to build/install" "node088")
        run_menu_action "build/install on: $nodes" cmd_build --nodes "$nodes"
        ;;
      5)
        local node selfish
        node=$(prompt_default "Node" "node088")
        selfish=$(prompt_default "selfish_mode (0 baseline, 1 selfish)" "1")
        run_menu_action "load ath9k on $node selfish_mode=$selfish" cmd_load_driver --node "$node" --selfish "$selfish"
        ;;
      6)
        local node ip
        node=$(prompt_default "AP node" "node069")
        ip=$(prompt_default "AP IP" "$AP_IP")
        run_menu_action "start AP on $node" cmd_start_ap --node "$node" --ip "$ip"
        ;;
      7)
        local node ip
        node=$(prompt_default "STA node" "node084")
        ip=$(prompt_required "STA IP, e.g. 192.168.2.2")
        run_menu_action "connect STA $node" cmd_connect_sta --node "$node" --ip "$ip"
        ;;
      8)
        local node port label
        node=$(prompt_default "Server node" "node084")
        port=$(prompt_default "UDP port" "5003")
        label=$(prompt_default "Log label" "server_$(date +%Y%m%d_%H%M%S)")
        run_menu_action "iperf server on $node" cmd_iperf_server --node "$node" --port "$port" --label "$label"
        ;;
      9)
        local node server_ip rate duration port label
        node=$(prompt_default "Client node" "node069")
        server_ip=$(prompt_required "Server IP")
        rate=$(prompt_default "Rate" "15M")
        duration=$(prompt_default "Duration seconds" "60")
        port=$(prompt_default "UDP port" "5003")
        label=$(prompt_default "Log label" "client_$(date +%Y%m%d_%H%M%S)")
        run_menu_action "iperf client $node -> $server_ip" cmd_iperf_client --node "$node" --server-ip "$server_ip" --rate "$rate" --duration "$duration" --port "$port" --label "$label"
        ;;
      10)
        local server client server_ip rate duration port label
        server=$(prompt_default "Server node" "node088")
        client=$(prompt_default "Client node" "node069")
        server_ip=$(prompt_required "Server IP")
        rate=$(prompt_default "Rate" "15M")
        duration=$(prompt_default "Duration seconds" "60")
        port=$(prompt_default "UDP port" "5003")
        label=$(prompt_default "Log label" "run_$(date +%Y%m%d_%H%M%S)")
        run_menu_action "iperf $client -> $server ($server_ip)" cmd_run_iperf --server "$server" --client "$client" --server-ip "$server_ip" --rate "$rate" --duration "$duration" --port "$port" --label "$label"
        ;;
      11)
        local server server_ip client_a client_b rates duration port prefix
        server=$(prompt_default "Server/AP node" "node069")
        server_ip=$(prompt_default "Server/AP IP" "$AP_IP")
        client_a=$(prompt_default "Client A / baseline STA" "node084")
        client_b=$(prompt_default "Client B / selfish STA" "node088")
        rates=$(prompt_default "Rates comma-separated" "5M,10M,15M,20M,25M")
        duration=$(prompt_default "Duration seconds per rate" "60")
        port=$(prompt_default "UDP port" "5003")
        prefix=$(prompt_default "Log prefix" "dual_sweep_$(date +%Y%m%d_%H%M%S)")
        run_menu_action "dual sweep $client_a+$client_b -> $server" cmd_run_dual_sweep --server "$server" --server-ip "$server_ip" --client-a "$client_a" --client-b "$client_b" --rates "$rates" --duration "$duration" --port "$port" --prefix "$prefix"
        ;;
      12)
        local server server_ip fixed_client fixed_rate sweep_client rates duration fixed_port sweep_port prefix
        server=$(prompt_default "Server/AP node" "node069")
        server_ip=$(prompt_default "Server/AP IP" "$AP_IP")
        fixed_client=$(prompt_default "Fixed-rate modified client" "node088")
        fixed_rate=$(prompt_default "Fixed client rate" "150M")
        sweep_client=$(prompt_default "Sweep client" "node086")
        rates=$(prompt_default "Sweep rates comma-separated" "5M,25M,50M,150M")
        duration=$(prompt_default "Duration seconds per rate" "60")
        fixed_port=$(prompt_default "Fixed client UDP port" "5003")
        sweep_port=$(prompt_default "Sweep client UDP port" "5004")
        prefix=$(prompt_default "Log prefix" "fixed150_sweep_$(date +%Y%m%d_%H%M%S)")
        run_menu_action "fixed+sweep $fixed_client+$sweep_client -> $server" cmd_run_fixed_sweep --server "$server" --server-ip "$server_ip" --fixed-client "$fixed_client" --fixed-rate "$fixed_rate" --sweep-client "$sweep_client" --rates "$rates" --duration "$duration" --fixed-port "$fixed_port" --sweep-port "$sweep_port" --prefix "$prefix"
        ;;
      13)
        local nodes out
        nodes=$(prompt_default "Nodes to collect from" "$NODES")
        out=$(prompt_default "Local output directory" "./selfish_collected_logs")
        run_menu_action "collect logs from: $nodes" cmd_collect_logs --nodes "$nodes" --out "$out"
        ;;
      14)
        local indir out
        indir=$(prompt_default "Collected log directory" "./selfish_collected_logs")
        out=$(prompt_default "CSV output" "$indir/iperf_summary.csv")
        run_menu_action "parse logs from: $indir" cmd_parse_logs --in "$indir" --out "$out"
        ;;
      15)
        local nodes
        nodes=$(prompt_default "Nodes for status" "$NODES")
        run_menu_action "status: $nodes" cmd_status --nodes "$nodes"
        ;;
      16)
        GATEWAY=$(prompt_default "Gateway" "$GATEWAY")
        NODES=$(prompt_default "Default nodes" "$NODES")
        SSID=$(prompt_default "SSID" "$SSID")
        CHANNEL=$(prompt_default "Channel" "$CHANNEL")
        AP_IP=$(prompt_default "AP IP" "$AP_IP")
        BACKPORTS_DIR=$(prompt_default "Backports dir" "$BACKPORTS_DIR")
        LOG_DIR=$(prompt_default "Node log dir" "$LOG_DIR")
        PATCH_FILE=$(prompt_default "Patch file" "$PATCH_FILE")
        SRC_REPO=$(prompt_default "Source repo" "$SRC_REPO")
        ;;
      h|H|help|--help)
        usage
        read -r -p "Press Enter to continue..." _
        ;;
      q|Q|quit|exit)
        echo "Bye."
        return 0
        ;;
      *)
        echo "Unknown option: $choice"
        sleep 1
        ;;
    esac
  done
}

cmd="${1:-}"; [[ $# -gt 0 ]] && shift || true
case "$cmd" in
  make-patch) cmd_make_patch "$@";;
  load-image) cmd_load_image "$@";;
  apply-patch) cmd_apply_patch "$@";;
  build) cmd_build "$@";;
  load-driver) cmd_load_driver "$@";;
  start-ap) cmd_start_ap "$@";;
  connect-sta) cmd_connect_sta "$@";;
  iperf-server) cmd_iperf_server "$@";;
  iperf-client) cmd_iperf_client "$@";;
  run-iperf) cmd_run_iperf "$@";;
  run-dual-sweep) cmd_run_dual_sweep "$@";;
  run-fixed-sweep) cmd_run_fixed_sweep "$@";;
  collect-logs) cmd_collect_logs "$@";;
  parse-logs) cmd_parse_logs "$@";;
  status) cmd_status "$@";;
  menu|interactive) interactive_menu;;
  -h|--help|help) usage;;
  "") interactive_menu;;
  *) echo "Unknown command: $cmd" >&2; usage; exit 1;;
esac
