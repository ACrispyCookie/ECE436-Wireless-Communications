#!/usr/bin/env bash
set -euo pipefail

# Capture AP1 hostapd_cli channel-switch beacons from AP2 while AP1<->fair STA runs iperf.
#
# Purpose:
#   - Configure AP1 as hostapd AP on the initial channel.
#   - Configure fair STA, associate it to AP1, and run STA->AP iperf.
#   - Start AP2 as a monitor-only capture node on AP1's initial channel.
#   - Trigger hostapd_cli chan_switch on AP1.
#   - Copy AP2's pcap and experiment logs back to the local results directory.
#
# Typical use:
#   ./capture_csa_beacons.sh --config experiment.conf
#
# Required config/env variables:
#   AP_NODE, FAIR_NODE, AP2_NODE
# Optional config/env variables use the same defaults as run.sh where practical.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GATEWAY="${GATEWAY:-nitlab3.inf.uth.gr}"
SLICE_NAME="${SLICE_NAME:-dtsiantos}"
NODE_LOG_DIR="${NODE_LOG_DIR:-/root/ece436_exp_logs}"
LOCAL_RESULTS_DIR="${LOCAL_RESULTS_DIR:-$SCRIPT_DIR/results}"

AP_NODE="${AP_NODE:-}"
FAIR_NODE="${FAIR_NODE:-}"
AP2_NODE="${AP2_NODE:-}"
AP_IP="${AP_IP:-192.168.2.1}"
FAIR_IP="${FAIR_IP:-192.168.2.2}"
SSID="${SSID:-tsiantos}"
CHANNEL="${CHANNEL:-1}"

WIFI_MODE="${WIFI_MODE:-n}"                  # n or g
PROTO="${PROTO:-udp}"                         # udp or tcp
RATE="${RATE:-150M}"
DURATION="${DURATION:-40}"
FAIR_PORT="${FAIR_PORT:-5004}"

SWITCH_DELAY_SECONDS="${SWITCH_DELAY_SECONDS:-10}"
SWITCH_CHANNEL="${SWITCH_CHANNEL:-6}"
CSA_COUNT="${CSA_COUNT:-5}"
CAPTURE_IFACE="${CAPTURE_IFACE:-mon_csa}"
CAPTURE_CHANNEL="${CAPTURE_CHANNEL:-}"
CAPTURE_EXTRA_SECONDS="${CAPTURE_EXTRA_SECONDS:-8}"
CAPTURE_FILTER="${CAPTURE_FILTER:-}"          # empty captures all frames; safest for analysis
LOAD_DRIVERS="${LOAD_DRIVERS:-1}"
LOCAL_OUT_DIR="${LOCAL_OUT_DIR:-}"
LABEL="${LABEL:-}"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no)
CONFIG_FILE=""

# Source --config first, then parse the full CLI so explicit options override the config file.
for ((arg_i=1; arg_i <= $#; arg_i++)); do
  if [[ "${!arg_i}" == "--config" ]]; then
    next_i=$((arg_i + 1))
    CONFIG_FILE="${!next_i:-}"
    [[ -n "$CONFIG_FILE" ]] || { echo "--config requires a file" >&2; exit 2; }
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    break
  fi
done

usage() {
  cat <<'EOF'
Usage:
  ./capture_csa_beacons.sh [options]

Options:
  --config FILE              Source experiment config before running.
  --ap-node NODE             AP1 node name, e.g. node069.
  --fair-node NODE           Fair STA node name, e.g. node063.
  --ap2-node NODE            AP2/capture node name, e.g. node075.
  --ssid SSID                AP1 SSID. Default: tsiantos.
  --channel CH               AP1 initial channel. Default: 1.
  --switch-channel CH        AP1 target channel/frequency for CSA. Default: 6.
  --switch-delay SEC         Seconds after iperf start before hostapd_cli chan_switch. Default: 10.
  --duration SEC             iperf duration. Default: 40.
  --rate RATE                UDP offered rate. Default: 150M.
  --proto udp|tcp            iperf protocol. Default: udp.
  --wifi-mode n|g            hostapd mode. Default: n.
  --capture-iface IFACE      AP2 monitor iface. Default: mon_csa.
  --capture-channel CH       AP2 capture channel. Default: AP1 initial channel.
  --capture-extra SEC        Capture duration is switch_delay + duration + extra. Default: 8.
  --capture-filter FILTER    Optional tcpdump filter. Empty default captures all frames.
  --out DIR                  Local output directory.
  --label LABEL              Remote experiment label under NODE_LOG_DIR.
  --no-driver-load           Do not reload ath9k drivers before setup.
  -h, --help                 Show this help.

Example:
  ./capture_csa_beacons.sh --config experiment.conf \
    --channel 1 --switch-channel 6 --switch-delay 10 --duration 40

Output:
  The AP2 pcap is copied under OUT/AP2_NODE/ and logs are copied under OUT/*/.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --ap-node) AP_NODE="$2"; shift 2 ;;
    --fair-node) FAIR_NODE="$2"; shift 2 ;;
    --ap2-node) AP2_NODE="$2"; shift 2 ;;
    --ssid) SSID="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --switch-channel) SWITCH_CHANNEL="$2"; shift 2 ;;
    --switch-delay) SWITCH_DELAY_SECONDS="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --rate) RATE="$2"; shift 2 ;;
    --proto) PROTO="$2"; shift 2 ;;
    --wifi-mode) WIFI_MODE="$2"; shift 2 ;;
    --capture-iface) CAPTURE_IFACE="$2"; shift 2 ;;
    --capture-channel) CAPTURE_CHANNEL="$2"; shift 2 ;;
    --capture-extra) CAPTURE_EXTRA_SECONDS="$2"; shift 2 ;;
    --capture-filter) CAPTURE_FILTER="$2"; shift 2 ;;
    --out) LOCAL_OUT_DIR="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --no-driver-load) LOAD_DRIVERS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# Re-apply defaults that depend on config/CLI values.
RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
CAPTURE_CHANNEL="${CAPTURE_CHANNEL:-$CHANNEL}"
LABEL="${LABEL:-csa_beacon_capture_$RUN_STAMP}"
LOCAL_OUT_DIR="${LOCAL_OUT_DIR:-$LOCAL_RESULTS_DIR/csa_beacon_capture_$RUN_STAMP}"
LOCAL_OUT_DIR="${LOCAL_OUT_DIR/#\~/$HOME}"

require_nonempty() {
  local missing=() k
  for k in AP_NODE FAIR_NODE AP2_NODE; do
    [[ -n "${!k:-}" ]] || missing+=("$k")
  done
  if (( ${#missing[@]} )); then
    echo "Missing required config: ${missing[*]}" >&2
    echo "Pass --config experiment.conf or set --ap-node/--fair-node/--ap2-node." >&2
    exit 2
  fi
}

validate() {
  require_nonempty
  [[ "$PROTO" == "udp" || "$PROTO" == "tcp" ]] || { echo "--proto must be udp or tcp" >&2; exit 2; }
  [[ "$WIFI_MODE" == "n" || "$WIFI_MODE" == "g" ]] || { echo "--wifi-mode must be n or g" >&2; exit 2; }
  for n in DURATION SWITCH_DELAY_SECONDS CAPTURE_EXTRA_SECONDS CSA_COUNT; do
    [[ "${!n}" =~ ^[0-9]+$ ]] || { echo "$n must be an integer" >&2; exit 2; }
  done
}

safe() { sed 's/[^A-Za-z0-9_.-]/_/g' <<<"$1"; }

gateway_target() {
  if [[ "$GATEWAY" == *@* || -z "${SLICE_NAME:-}" ]]; then
    printf '%s' "$GATEWAY"
  else
    printf '%s@%s' "$SLICE_NAME" "$GATEWAY"
  fi
}

gw() { ssh "${SSH_OPTS[@]}" "$(gateway_target)" "$@"; }

node_bash() {
  local node="$1" script="$2"
  gw "ssh -o StrictHostKeyChecking=no root@'$node' 'bash -s'" <<<"$script"
}

channel_to_freq_mhz() {
  local channel="$1"
  if [[ "$channel" =~ ^[0-9]+$ ]] && (( channel > 1000 )); then
    printf '%s' "$channel"
  elif [[ "$channel" == "14" ]]; then
    printf '2484'
  elif [[ "$channel" =~ ^[0-9]+$ ]] && (( channel >= 1 && channel <= 13 )); then
    printf '%s' $((2407 + 5 * channel))
  else
    echo "Unsupported channel/frequency: $channel" >&2
    return 1
  fi
}

copy_remote_file() {
  local node="$1" remote_path="$2" local_dir="$3"
  mkdir -p "$local_dir"
  local base tmp
  base="$(basename "$remote_path")"
  tmp="/tmp/${node}_${base}_$$"
  echo "[fetch] $node:$remote_path -> $local_dir/$base"
  gw "scp -o StrictHostKeyChecking=no root@'$node':'$remote_path' '$tmp'"
  scp "${SSH_OPTS[@]}" "$(gateway_target):$tmp" "$local_dir/$base"
  gw "rm -f '$tmp'" || true
}

copy_remote_dir_tar() {
  local node="$1" remote_dir="$2" local_dir="$3"
  mkdir -p "$local_dir"
  local tarname tmp
  tarname="${node}_$(basename "$remote_dir")_logs.tar.gz"
  tmp="/tmp/${tarname}_$$"
  echo "[fetch] $node:$remote_dir -> $local_dir/$tarname"
  node_bash "$node" "
set -euo pipefail
if [[ -d '$remote_dir' ]]; then
  tar czf '$tmp' -C '$remote_dir' .
else
  mkdir -p /tmp/empty_csa_capture_dir
  tar czf '$tmp' -C /tmp/empty_csa_capture_dir .
fi
"
  gw "scp -o StrictHostKeyChecking=no root@'$node':'$tmp' '$tmp'"
  scp "${SSH_OPTS[@]}" "$(gateway_target):$tmp" "$local_dir/$tarname"
  tar xzf "$local_dir/$tarname" -C "$local_dir"
  gw "rm -f '$tmp'" || true
  gw "ssh -o StrictHostKeyChecking=no root@'$node' 'rm -f '$tmp''" || true
}

load_driver_plain() {
  local node="$1"
  [[ "$LOAD_DRIVERS" == "1" ]] || return 0
  echo "[driver] reload plain ath9k stack on $node"
  node_bash "$node" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/$LABEL'
{
  date -Is
  killall hostapd 2>/dev/null || true
  ip link set '$CAPTURE_IFACE' down 2>/dev/null || true
  iw dev '$CAPTURE_IFACE' del 2>/dev/null || true
  ip link set wlan0 down 2>/dev/null || true
  modprobe -r ath9k ath9k_common ath9k_hw ath mac80211 cfg80211 2>/dev/null || true
  modprobe ath9k
  ip link show wlan0 || true
  iw dev || true
} 2>&1 | tee '$NODE_LOG_DIR/$LABEL/${node}_driver_reload.log'
"
}

start_ap1() {
  local ieee80211n=1 hw_mode=g
  [[ "$WIFI_MODE" == "g" ]] && ieee80211n=0
  echo "[ap1] start hostapd on $AP_NODE ssid=$SSID channel=$CHANNEL mode=$WIFI_MODE"
  node_bash "$AP_NODE" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/$LABEL' /var/run/hostapd
if ! command -v hostapd >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt install -y hostapd
fi
cat > /root/ece436_csa_ap1.conf <<EOF_AP
interface=wlan0
driver=nl80211
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
ssid=$SSID
hw_mode=$hw_mode
channel=$CHANNEL
ieee80211n=$ieee80211n
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
EOF_AP
killall hostapd 2>/dev/null || true
ip link set wlan0 down 2>/dev/null || true
ifconfig wlan0 '$AP_IP' up
nohup hostapd -dd /root/ece436_csa_ap1.conf > '$NODE_LOG_DIR/$LABEL/${AP_NODE}_hostapd_ap1.log' 2>&1 & echo \$! > '$NODE_LOG_DIR/$LABEL/${AP_NODE}_hostapd.pid'
sleep 2
{
  date -Is
  hostapd_cli -p /var/run/hostapd -i wlan0 status || true
  iw dev wlan0 info || true
  tail -60 '$NODE_LOG_DIR/$LABEL/${AP_NODE}_hostapd_ap1.log' || true
} 2>&1 | tee '$NODE_LOG_DIR/$LABEL/${AP_NODE}_ap1_status_after_start.log'
"
}

connect_fair_sta() {
  echo "[fair] connect $FAIR_NODE to SSID=$SSID ip=$FAIR_IP"
  node_bash "$FAIR_NODE" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/$LABEL'
ip link set wlan0 down 2>/dev/null || true
ifconfig wlan0 '$FAIR_IP' up
iw dev wlan0 disconnect 2>/dev/null || true
iw dev wlan0 connect '$SSID' || true
sleep 3
{
  date -Is
  ip addr show wlan0
  iw dev wlan0 link || true
  ping -c 5 '$AP_IP' || true
} 2>&1 | tee '$NODE_LOG_DIR/$LABEL/${FAIR_NODE}_connect_${SSID}.log'
"
}

start_iperf_server() {
  local udpflag="-u"
  [[ "$PROTO" == "tcp" ]] && udpflag=""
  echo "[iperf] start AP1 server on $AP_NODE port=$FAIR_PORT proto=$PROTO"
  node_bash "$AP_NODE" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/$LABEL'
if ! command -v iperf >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt install -y iperf
fi
if [[ -f '$NODE_LOG_DIR/$LABEL/iperf_server_${FAIR_PORT}.pid' ]]; then
  old_pid=\$(cat '$NODE_LOG_DIR/$LABEL/iperf_server_${FAIR_PORT}.pid' 2>/dev/null || true)
  [[ -n \"\${old_pid:-}\" ]] && kill \"\$old_pid\" 2>/dev/null || true
fi
nohup iperf -s $udpflag -p '$FAIR_PORT' -i 1 > '$NODE_LOG_DIR/$LABEL/${AP_NODE}_iperf_${PROTO}_server_p${FAIR_PORT}.log' 2>&1 & echo \$! > '$NODE_LOG_DIR/$LABEL/iperf_server_${FAIR_PORT}.pid'
sleep 1
tail -5 '$NODE_LOG_DIR/$LABEL/${AP_NODE}_iperf_${PROTO}_server_p${FAIR_PORT}.log' || true
"
}

start_ap2_capture() {
  local capture_seconds=$((SWITCH_DELAY_SECONDS + DURATION + CAPTURE_EXTRA_SECONDS))
  echo "[capture] AP2 $AP2_NODE monitor=$CAPTURE_IFACE channel=$CAPTURE_CHANNEL duration=${capture_seconds}s"
  node_bash "$AP2_NODE" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/$LABEL'
if ! command -v tcpdump >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt install -y tcpdump
fi
killall hostapd 2>/dev/null || true
if [[ -f '$NODE_LOG_DIR/$LABEL/ap2_capture.pid' ]]; then
  old_pid=\$(cat '$NODE_LOG_DIR/$LABEL/ap2_capture.pid' 2>/dev/null || true)
  [[ -n \"\${old_pid:-}\" ]] && kill \"\$old_pid\" 2>/dev/null || true
fi
ip link set '$CAPTURE_IFACE' down 2>/dev/null || true
iw dev '$CAPTURE_IFACE' del 2>/dev/null || true
ip link set wlan0 down 2>/dev/null || true
iw dev wlan0 interface add '$CAPTURE_IFACE' type monitor
ip link set '$CAPTURE_IFACE' up
iw dev '$CAPTURE_IFACE' set channel '$CAPTURE_CHANNEL'
{
  date -Is
  echo 'capture_node=$AP2_NODE'
  echo 'capture_iface=$CAPTURE_IFACE'
  echo 'capture_channel=$CAPTURE_CHANNEL'
  echo 'capture_seconds=$capture_seconds'
  iw dev '$CAPTURE_IFACE' info || true
  iw dev || true
} 2>&1 | tee '$NODE_LOG_DIR/$LABEL/${AP2_NODE}_capture_setup.log'
pcap='$NODE_LOG_DIR/$LABEL/${AP2_NODE}_ap1_csa_beacons_ch${CHANNEL}_to_ch${SWITCH_CHANNEL}.pcap'
log='$NODE_LOG_DIR/$LABEL/${AP2_NODE}_tcpdump_capture.log'
if [[ -n '$CAPTURE_FILTER' ]]; then
  nohup timeout '$capture_seconds' tcpdump -i '$CAPTURE_IFACE' -s 0 -U -w \"\$pcap\" '$CAPTURE_FILTER' > \"\$log\" 2>&1 & echo \$! > '$NODE_LOG_DIR/$LABEL/ap2_capture.pid'
else
  nohup timeout '$capture_seconds' tcpdump -i '$CAPTURE_IFACE' -s 0 -U -w \"\$pcap\" > \"\$log\" 2>&1 & echo \$! > '$NODE_LOG_DIR/$LABEL/ap2_capture.pid'
fi
sleep 1
cat '$NODE_LOG_DIR/$LABEL/ap2_capture.pid'
tail -20 \"\$log\" || true
"
}

schedule_csa() {
  local freq
  freq="$(channel_to_freq_mhz "$SWITCH_CHANNEL")"
  echo "[csa] schedule AP1 switch after ${SWITCH_DELAY_SECONDS}s to channel=$SWITCH_CHANNEL freq=$freq"
  node_bash "$AP_NODE" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/$LABEL'
task='/tmp/ece436_ap1_csa_${LABEL}.sh'
cat > \"\$task\" <<'EOF_CSA_TASK'
#!/usr/bin/env bash
set -euo pipefail
{
  echo '[csa] scheduled AP1 hostapd_cli channel switch'
  echo date_scheduled=\$(date -Is)
  echo 'initial_channel=$CHANNEL'
  echo 'target_channel=$SWITCH_CHANNEL'
  echo 'target_frequency_mhz=$freq'
  echo 'delay_seconds=$SWITCH_DELAY_SECONDS'
  sleep '$SWITCH_DELAY_SECONDS'
  echo date_before_switch=\$(date -Is)
  hostapd_cli -p /var/run/hostapd -i wlan0 status || true
  iw dev wlan0 info || true
  echo '[csa] command: hostapd_cli -p /var/run/hostapd -i wlan0 chan_switch $CSA_COUNT $freq'
  hostapd_cli -p /var/run/hostapd -i wlan0 chan_switch '$CSA_COUNT' '$freq'
  sleep 3
  echo date_after_switch=\$(date -Is)
  hostapd_cli -p /var/run/hostapd -i wlan0 status || true
  iw dev wlan0 info || true
  dmesg 2>/dev/null | grep -iE 'ath9k|cfg80211|nl80211|channel|csa|switch' | tail -80 || true
} 2>&1
EOF_CSA_TASK
chmod +x \"\$task\"
nohup bash \"\$task\" > '$NODE_LOG_DIR/$LABEL/${AP_NODE}_hostapd_cli_chan_switch_ch${SWITCH_CHANNEL}.log' 2>&1 & echo \$! > '$NODE_LOG_DIR/$LABEL/ap1_csa_task.pid'
cat '$NODE_LOG_DIR/$LABEL/ap1_csa_task.pid'
"
}

run_iperf_client() {
  local cmd
  if [[ "$PROTO" == "tcp" ]]; then
    cmd="iperf -c '$AP_IP' -p '$FAIR_PORT' -t '$DURATION' -i 1"
  else
    cmd="iperf -c '$AP_IP' -u -p '$FAIR_PORT' -b '$RATE' -t '$DURATION' -i 1"
  fi
  echo "[iperf] run fair STA client on $FAIR_NODE: $cmd"
  node_bash "$FAIR_NODE" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/$LABEL'
if ! command -v iperf >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt install -y iperf
fi
{
  date
  iw dev wlan0 link || true
  echo '$cmd'
  $cmd
  echo '[post-iperf link]'
  iw dev wlan0 link || true
} 2>&1 | tee '$NODE_LOG_DIR/$LABEL/${FAIR_NODE}_iperf_${PROTO}_client_to_${AP_IP}_${RATE}_${DURATION}s_p${FAIR_PORT}.log'
"
}

wait_for_remote_tasks() {
  local capture_seconds=$((SWITCH_DELAY_SECONDS + DURATION + CAPTURE_EXTRA_SECONDS))
  echo "[wait] allow remote CSA and tcpdump to finish"
  node_bash "$AP_NODE" "
set -euo pipefail
if [[ -f '$NODE_LOG_DIR/$LABEL/ap1_csa_task.pid' ]]; then
  pid=\$(cat '$NODE_LOG_DIR/$LABEL/ap1_csa_task.pid' 2>/dev/null || true)
  if [[ -n \"\${pid:-}\" ]]; then wait \"\$pid\" 2>/dev/null || true; fi
fi
"
  node_bash "$AP2_NODE" "
set -euo pipefail
if [[ -f '$NODE_LOG_DIR/$LABEL/ap2_capture.pid' ]]; then
  pid=\$(cat '$NODE_LOG_DIR/$LABEL/ap2_capture.pid' 2>/dev/null || true)
  if [[ -n \"\${pid:-}\" ]]; then
    for i in \$(seq 1 $((capture_seconds + 5))); do
      kill -0 \"\$pid\" 2>/dev/null || break
      sleep 1
    done
    kill -INT \"\$pid\" 2>/dev/null || true
    sleep 1
  fi
fi
ls -lh '$NODE_LOG_DIR/$LABEL'/*.pcap 2>/dev/null || true
"
}

write_local_metadata() {
  mkdir -p "$LOCAL_OUT_DIR"
  cat > "$LOCAL_OUT_DIR/README.txt" <<EOF_README
CSA beacon capture run
======================
label=$LABEL
ap_node=$AP_NODE
fair_node=$FAIR_NODE
ap2_capture_node=$AP2_NODE
ssid=$SSID
initial_channel=$CHANNEL
capture_channel=$CAPTURE_CHANNEL
switch_channel=$SWITCH_CHANNEL
switch_delay_seconds=$SWITCH_DELAY_SECONDS
csa_count=$CSA_COUNT
proto=$PROTO
rate=$RATE
duration_seconds=$DURATION
fair_port=$FAIR_PORT
pcap_hint=Open AP2_NODE/*ap1_csa_beacons*.pcap in Wireshark and inspect Beacon frames around the CSA time. Look for Channel Switch Announcement information element (ID 37) and DS Parameter Set/HT Operation channel fields.
EOF_README
}

collect_outputs() {
  echo "[collect] local output: $LOCAL_OUT_DIR"
  write_local_metadata
  copy_remote_dir_tar "$AP_NODE" "$NODE_LOG_DIR/$LABEL" "$LOCAL_OUT_DIR/$AP_NODE"
  copy_remote_dir_tar "$FAIR_NODE" "$NODE_LOG_DIR/$LABEL" "$LOCAL_OUT_DIR/$FAIR_NODE"
  copy_remote_dir_tar "$AP2_NODE" "$NODE_LOG_DIR/$LABEL" "$LOCAL_OUT_DIR/$AP2_NODE"
  local pcap_remote="$NODE_LOG_DIR/$LABEL/${AP2_NODE}_ap1_csa_beacons_ch${CHANNEL}_to_ch${SWITCH_CHANNEL}.pcap"
  # Explicit pcap copy keeps the important artifact obvious even though it is also in the tar extraction.
  copy_remote_file "$AP2_NODE" "$pcap_remote" "$LOCAL_OUT_DIR/$AP2_NODE" || true
  echo "[collect] files:"
  find "$LOCAL_OUT_DIR" -maxdepth 3 -type f | sort
}

main() {
  validate
  echo "CSA beacon capture experiment"
  echo "  gateway: $(gateway_target)"
  echo "  label: $LABEL"
  echo "  AP1: $AP_NODE ip=$AP_IP ssid=$SSID ch=$CHANNEL -> ch=$SWITCH_CHANNEL"
  echo "  fair STA: $FAIR_NODE ip=$FAIR_IP proto=$PROTO rate=$RATE duration=${DURATION}s"
  echo "  AP2 capture: $AP2_NODE iface=$CAPTURE_IFACE ch=$CAPTURE_CHANNEL"
  echo "  local out: $LOCAL_OUT_DIR"

  load_driver_plain "$AP_NODE"
  load_driver_plain "$FAIR_NODE"
  load_driver_plain "$AP2_NODE"
  start_ap1
  connect_fair_sta
  start_iperf_server
  start_ap2_capture
  schedule_csa
  run_iperf_client
  wait_for_remote_tasks
  collect_outputs
  echo "DONE: $LOCAL_OUT_DIR"
}

main "$@"
