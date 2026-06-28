#!/usr/bin/env bash
set -euo pipefail

# ECE436 ath9k/NITLab experiment suite.
# Interactive by default: ./run.sh
# Non-interactive examples:
#   ./run.sh generate-patch my.patch
#   ./run.sh load-config experiment.conf
#   ./run.sh fetch-results ./collected_logs
#   ./run.sh parse-results ./collected_logs
#
# Results are collected as one directory per experiment. Each experiment stores
# its settings in experiment.conf; driver options are kept out of directory names.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Persistent/default settings ----------
GATEWAY="${GATEWAY:-nitlab3.inf.uth.gr}"
SLICE_NAME="${SLICE_NAME:-dtsiantos}"
IMAGE="${IMAGE:-baseline_wireless_communications.ndz}"
BACKPORTS_DIR="${BACKPORTS_DIR:-/root/backports-5.4.56-1}"
NODE_LOG_DIR="${NODE_LOG_DIR:-/root/ece436_exp_logs}"
LOCAL_RESULTS_DIR="${LOCAL_RESULTS_DIR:-$SCRIPT_DIR/results}"
PLOTS_DIR="${PLOTS_DIR:-$SCRIPT_DIR/plots}"
PATCH_FILE="${PATCH_FILE:-$SCRIPT_DIR/ath9k_experiment.patch}"
SRC_REPO="${SRC_REPO:-$SCRIPT_DIR}"
BASE_REF="${BASE_REF:-origin/baseline}"

AP_NODE="${AP_NODE:-}"
AP2_NODE="${AP2_NODE:-}"
FAIR_NODE="${FAIR_NODE:-}"
UNFAIR_NODE="${UNFAIR_NODE:-}"
AP_IP="${AP_IP:-192.168.2.1}"
AP2_IP="${AP2_IP:-192.168.2.4}"
FAIR_IP="${FAIR_IP:-192.168.2.2}"
UNFAIR_IP="${UNFAIR_IP:-192.168.2.3}"
SSID="${SSID:-tsiantos}"
AP2_SSID="${AP2_SSID:-${SSID}_ap2}"
CHANNEL="${CHANNEL:-7}"
RATES="${RATES:-5M,25M,50M,150M}"
DURATION="${DURATION:-60}"
FIXED_RATE_DEFAULT="${FIXED_RATE_DEFAULT:-150M}"
DUAL_FAIR_LEAD_SECONDS="${DUAL_FAIR_LEAD_SECONDS:-10}"

# Driver module options passed to ath9k_hw. Keep every known custom option
# explicit in labels/configs so result directories document the exact mode.
# NOTE: "chanel_idle" intentionally preserves the driver's exported typo.
FAIR_DRIVER_OPTS="${FAIR_DRIVER_OPTS:-selfish_mode=0 disable_backoff=0 chanel_idle=0 selfish_txop_us=0}"
UNFAIR_DRIVER_OPTS="${UNFAIR_DRIVER_OPTS:-selfish_mode=0 disable_backoff=0 chanel_idle=0 selfish_txop_us=0}"

# IPERF defaults. iperf2 is assumed because NITLab images used iperf2 in previous tests.
FAIR_PORT="${FAIR_PORT:-5004}"
UNFAIR_PORT="${UNFAIR_PORT:-5003}"
TCP_PORT_BASE="${TCP_PORT_BASE:-5010}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no)

# ---------- Small helpers ----------
require_nodes_config() {
  local missing=() k
  for k in AP_NODE FAIR_NODE UNFAIR_NODE; do
    [[ -n "${!k:-}" ]] || missing+=("$k")
  done
  if (( ${#missing[@]} )); then
    echo "Missing node configuration: ${missing[*]}" >&2
    echo "Load an experiment .conf first, for example: ./run.sh load-config experiment.conf" >&2
    echo "Or use the interactive menu: Setup -> 7) load settings from config" >&2
    return 1
  fi
}

require_two_ap_nodes_config() {
  require_nodes_config || return 1
  if [[ -z "${AP2_NODE:-}" ]]; then
    echo "Missing node configuration: AP2_NODE" >&2
    echo "Set AP2_NODE in experiment.conf or Setup -> 2) set default nodes." >&2
    return 1
  fi
}

all_nodes_csv() {
  require_nodes_config || return 1
  if [[ -n "${AP2_NODE:-}" ]]; then
    printf '%s,%s,%s,%s' "$AP_NODE" "$AP2_NODE" "$FAIR_NODE" "$UNFAIR_NODE"
  else
    printf '%s,%s,%s' "$AP_NODE" "$FAIR_NODE" "$UNFAIR_NODE"
  fi
}

all_nodes_csv_or_empty() {
  if [[ -n "${AP_NODE:-}" && -n "${FAIR_NODE:-}" && -n "${UNFAIR_NODE:-}" ]]; then
    if [[ -n "${AP2_NODE:-}" ]]; then
      printf '%s,%s,%s,%s' "$AP_NODE" "$AP2_NODE" "$FAIR_NODE" "$UNFAIR_NODE"
    else
      printf '%s,%s,%s' "$AP_NODE" "$FAIR_NODE" "$UNFAIR_NODE"
    fi
  fi
}
split_csv() { tr ',' ' ' <<<"$1"; }
ts() { date +%Y%m%d_%H%M%S; }
safe() { sed 's/[^A-Za-z0-9_.-]/_/g' <<<"$1"; }
join_opts_tag() { local x="${1:-none}"; x="${x// /_}"; safe "$x"; }
rate_tag() { safe "$1"; }

script_path() {
  local path="$1"
  [[ -z "$path" ]] && return 0
  if [[ "$path" == /* ]]; then
    printf '%s' "$path"
  else
    printf '%s/%s' "$SCRIPT_DIR" "$path"
  fi
}

normalize_path_settings() {
  LOCAL_RESULTS_DIR="$(script_path "$LOCAL_RESULTS_DIR")"
  PLOTS_DIR="$(script_path "$PLOTS_DIR")"
  PATCH_FILE="$(script_path "$PATCH_FILE")"
  SRC_REPO="$(script_path "$SRC_REPO")"
}

gateway_target() {
  if [[ "$GATEWAY" == *@* || -z "${SLICE_NAME:-}" ]]; then
    printf '%s' "$GATEWAY"
  else
    printf '%s@%s' "$SLICE_NAME" "$GATEWAY"
  fi
}

normalize_path_settings

get_opt_value() {
  local opts="$1" key="$2" default="${3:-0}" token
  for token in $opts; do
    if [[ "$token" == "$key="* ]]; then
      printf '%s' "${token#*=}"
      return 0
    fi
  done
  printf '%s' "$default"
}

ensure_opt() {
  local opts="$1" key="$2" default="$3"
  if [[ " $opts " == *" $key="* ]]; then
    printf '%s' "$opts"
  else
    printf '%s %s=%s' "$opts" "$key" "$default"
  fi
}

normalize_driver_opts() {
  FAIR_DRIVER_OPTS="$(ensure_opt "$FAIR_DRIVER_OPTS" selfish_txop_us 0)"
  UNFAIR_DRIVER_OPTS="$(ensure_opt "$UNFAIR_DRIVER_OPTS" selfish_txop_us 0)"
}

bool_default_letter() {
  local value="${1:-0}"
  if [[ "$value" == "1" || "$value" =~ ^[Yy] ]]; then printf 'y'; else printf 'n'; fi
}

compose_driver_opts_prompt() {
  local label="$1" current="$2" selfish disable idle txop opts
  echo "Current $label options: ${current:-<none>}" >&2
  if prompt_yes_no "$label: selfish_mode" "$(bool_default_letter "$(get_opt_value "$current" selfish_mode 0)")"; then selfish=1; else selfish=0; fi
  if prompt_yes_no "$label: disable_backoff" "$(bool_default_letter "$(get_opt_value "$current" disable_backoff 0)")"; then disable=1; else disable=0; fi
  if prompt_yes_no "$label: chanel_idle (driver typo, AR_DIAG_FORCE_CH_IDLE_HIGH)" "$(bool_default_letter "$(get_opt_value "$current" chanel_idle 0)")"; then idle=1; else idle=0; fi
  txop=$(prompt_default "$label: selfish_txop_us (0 disables custom TXOP)" "$(get_opt_value "$current" selfish_txop_us 0)")
  opts="selfish_mode=$selfish disable_backoff=$disable chanel_idle=$idle selfish_txop_us=$txop"
  printf '%s' "$opts"
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

prompt_yes_no() {
  local prompt="$1" default="${2:-n}" value suffix
  if [[ "$default" =~ ^[Yy]$ ]]; then suffix="Y/n"; else suffix="y/N"; fi
  read -r -p "$prompt [$suffix]: " value
  value="${value:-$default}"
  [[ "$value" =~ ^[Yy]$ ]]
}

prompt_choice() {
  local prompt="$1" value
  shift
  while true; do
    echo "$prompt" >&2
    local i=1
    for item in "$@"; do echo "  $i) $item" >&2; ((i++)); done
    read -r -p "Select: " value
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= $# )); then
      printf '%s' "$value"
      return 0
    fi
    echo "Invalid choice." >&2
  done
}

prompt_protocol() {
  local choice
  choice=$(prompt_choice "Protocol:" "UDP" "TCP")
  case "$choice" in
    1) printf 'udp' ;;
    2) printf 'tcp' ;;
  esac
}

prompt_wifi_mode() {
  local choice
  choice=$(prompt_choice "802.11 version:" "802.11n" "802.11g")
  case "$choice" in
    1) printf 'n' ;;
    2) printf 'g' ;;
  esac
}

pause() { read -r -p "Press Enter to continue..." _ || true; }

soft_clear() {
  # Like Ctrl-L/readline clear-screen: clear the visible viewport without
  # asking the terminal to erase scrollback history (unlike some `clear`s).
  printf '\033[H\033[2J'
}

settings_summary() {
  cat <<EOF
Gateway:           $GATEWAY
Slice name:        ${SLICE_NAME:-<unset>}
Gateway SSH:       $(gateway_target)
Image:             $IMAGE
Backports dir:     $BACKPORTS_DIR
Node log dir:      $NODE_LOG_DIR
Local results dir: $LOCAL_RESULTS_DIR
Plots dir:         $PLOTS_DIR
Patch file:        $PATCH_FILE
Source repo:       $SRC_REPO
Base ref:          $BASE_REF
AP1:               ${AP_NODE:-<unset>} ($AP_IP, SSID=$SSID)
AP2:               ${AP2_NODE:-<unset>} ($AP2_IP, SSID=$AP2_SSID)
Fair STA:          ${FAIR_NODE:-<unset>} ($FAIR_IP)
Unfair STA:        ${UNFAIR_NODE:-<unset>} ($UNFAIR_IP)
Channel:           $CHANNEL
Default rates:     $RATES
Duration:          ${DURATION}s
Fair driver opts:  ${FAIR_DRIVER_OPTS:-<none>}
Unfair drv opts:   ${UNFAIR_DRIVER_OPTS:-<none>}
EOF
}

gw() { ssh "${SSH_OPTS[@]}" "$(gateway_target)" "$@"; }
node_bash() {
  local node="$1" script="$2"
  gw "ssh -o StrictHostKeyChecking=no root@${node} 'bash -s'" <<<"$script"
}

run_action() {
  local title="$1"; shift
  echo
  echo "==> $title"
  if "$@"; then
    echo "==> Done: $title"
  else
    local rc=$?
    echo "==> FAILED ($rc): $title" >&2
  fi
  echo
}

# ---------- Config load/store ----------
config_keys=(
  GATEWAY SLICE_NAME IMAGE BACKPORTS_DIR NODE_LOG_DIR LOCAL_RESULTS_DIR PLOTS_DIR PATCH_FILE SRC_REPO BASE_REF
  AP_NODE AP2_NODE FAIR_NODE UNFAIR_NODE AP_IP AP2_IP FAIR_IP UNFAIR_IP SSID AP2_SSID CHANNEL RATES DURATION FIXED_RATE_DEFAULT DUAL_FAIR_LEAD_SECONDS
  FAIR_DRIVER_OPTS UNFAIR_DRIVER_OPTS FAIR_PORT UNFAIR_PORT TCP_PORT_BASE
)

config_content() {
  echo "# ECE436 ath9k experiment-suite config"
  echo "# Generated: $(date -Is)"
  local k
  for k in "${config_keys[@]}"; do
    printf '%s=%q\n' "$k" "${!k}"
  done
}

export_config() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  config_content > "$file"
  echo "Wrote config: $file"
}

load_config() {
  local file="$1"
  [[ -f "$file" ]] || { echo "Config not found: $file" >&2; return 1; }
  # Accept only simple KEY=VALUE assignments for known keys.
  local tmp
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^([A-Z0-9_]+)= ]]; then
      local key="${BASH_REMATCH[1]}" ok=0 k
      for k in "${config_keys[@]}"; do [[ "$key" == "$k" ]] && ok=1; done
      if [[ "$ok" -eq 1 ]]; then
        printf '%s\n' "$line" >> "$tmp"
      else
        echo "Ignoring unknown config key: $key" >&2
      fi
    else
      echo "Ignoring invalid config line: $line" >&2
    fi
  done < "$file"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
  normalize_driver_opts
  normalize_path_settings
  echo "Loaded config: $file"
}

load_default_config_if_present() {
  local file="$SCRIPT_DIR/experiment.conf"
  if [[ -f "$file" ]]; then
    load_config "$file"
  else
    echo "Default config not found: $file" >&2
    echo "Use Setup -> 8) export settings to config after configuring nodes." >&2
  fi
}

# ---------- Setup commands ----------
generate_patch() {
  local patch_name="${1:-}"
  if [[ -z "$patch_name" ]]; then patch_name="$PATCH_FILE"; fi
  [[ "$patch_name" == /* ]] || patch_name="$SCRIPT_DIR/$patch_name"
  [[ -d "$SRC_REPO/.git" ]] || { echo "SRC_REPO is not a git repo: $SRC_REPO" >&2; return 1; }
  mkdir -p "$(dirname "$patch_name")"
  git -C "$SRC_REPO" diff --binary --relative=backports-5.4.56-1 "$BASE_REF" -- \
    backports-5.4.56-1/drivers/net/wireless/ath/ath9k \
    > "$patch_name"
  if [[ ! -s "$patch_name" ]]; then
    echo "Patch is empty. Check BASE_REF=$BASE_REF or local changes." >&2
    return 1
  fi
  PATCH_FILE="$patch_name"
  echo "Created patch: $PATCH_FILE"
}

load_image_to_nodes() {
  local nodes="${1:-}"
  if [[ -z "$nodes" ]]; then nodes="$(all_nodes_csv)" || return 1; fi
  echo "[omf] image=$IMAGE nodes=$nodes"
  echo "[ssh] gateway=$(gateway_target)"
  echo "Do not interrupt OMF load after it starts."
  gw "omf load -i '$IMAGE' -t '$nodes'"
  echo "OMF command finished. Waiting for SSH readiness..."
  echo "This can take a few minutes after imaging; the script polls root SSH on each selected node."
  local n
  for n in $(split_csv "$nodes"); do
    echo "[wait-ssh] $n"
    gw "for i in \$(seq 1 60); do if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@'$n' hostname >/dev/null 2>&1; then echo '[wait-ssh] $n is ready'; exit 0; fi; printf '[wait-ssh] $n not ready yet (%02d/60)\\n' \"\$i\"; sleep 5; done; echo 'WARNING: root@$n not SSH-ready after 5 minutes' >&2; exit 0"
  done
}

# ---------- Driver/network node commands ----------
send_patch_to_node() {
  local node="$1" patch_file="${2:-$PATCH_FILE}" remote_patch="/tmp/ece436_$(basename "$patch_file")"
  patch_file="$(script_path "$patch_file")"
  [[ -s "$patch_file" ]] || { echo "Patch file not found or empty: $patch_file" >&2; return 1; }
  echo "[patch] copy $patch_file -> $node:$remote_patch"
  scp "${SSH_OPTS[@]}" "$patch_file" "$(gateway_target):/tmp/$(basename "$patch_file")"
  gw "scp -o StrictHostKeyChecking=no '/tmp/$(basename "$patch_file")' root@'$node':'$remote_patch'"
}

apply_patch_on_node() {
  local node="$1" patch_file="${2:-$PATCH_FILE}" remote_patch="/tmp/ece436_$(basename "$patch_file")"
  send_patch_to_node "$node" "$patch_file" || return 1
  echo "[patch] apply on $node in $BACKPORTS_DIR"
  node_bash "$node" "
set -euo pipefail
cd '$BACKPORTS_DIR'
if patch --dry-run -p1 < '$remote_patch' >/tmp/ece436_patch_check.log 2>&1; then
  patch -p1 < '$remote_patch'
  echo '[patch] applied'
elif patch --reverse --dry-run -p1 < '$remote_patch' >/tmp/ece436_patch_reverse_check.log 2>&1; then
  echo '[patch] already applied; leaving tree as-is'
else
  echo '[patch] cannot apply cleanly. Dry-run output:' >&2
  cat /tmp/ece436_patch_check.log >&2 || true
  echo '[patch] reverse dry-run output:' >&2
  cat /tmp/ece436_patch_reverse_check.log >&2 || true
  exit 1
fi
"
}

build_driver_on_node() {
  local node="$1"
  echo "[build] $node backports in $BACKPORTS_DIR"
  node_bash "$node" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/setup'
cd '$BACKPORTS_DIR'
log='$NODE_LOG_DIR/setup/${node}_backports_build_$(ts).log'
{
  date
  echo '[build] kernel='\"\$(uname -r)\"
  command -v make
  command -v gcc || true
  echo '[build] unloading ath9k stack if loaded'
  killall hostapd 2>/dev/null || true
  ip link set wlan0 down 2>/dev/null || true
  modprobe -r ath9k ath9k_common ath9k_hw ath mac80211 cfg80211 2>/dev/null || true
  if [[ ! -f .config ]]; then
    echo '[build] no .config; running make defconfig-ath9k'
    make defconfig-ath9k
  else
    echo '[build] existing .config found; keeping it'
  fi
  echo '[build] make -j'\"\$(nproc)\"
  make -j\"\$(nproc)\"
  echo '[build] make install'
  set +e
  make install
  install_rc=\$?
  set -e
  echo '[build] make install rc='\"\$install_rc\"
  echo '[build] depmod -a'
  depmod -a || true
  echo '[build] installed module info/params:'
  modinfo ath9k_hw 2>/dev/null | grep -E '^(filename|version|parm):' || true
  missing_params=''
  for p in selfish_mode disable_backoff chanel_idle selfish_txop_us; do
    if ! modinfo ath9k_hw 2>/dev/null | grep -qE '^parm:[[:space:]]*'\"\$p\"'[: ]'; then
      missing_params=\"\$missing_params \$p\"
    fi
  done
  if [[ -n \"\$missing_params\" ]]; then
    echo '[build] ERROR: installed ath9k_hw is missing custom params:'\"\$missing_params\" >&2
    echo '[build] This usually means the patch was not applied to the source being built, or make install installed a different/stock module.' >&2
    exit 1
  fi
  if [[ \"\$install_rc\" -ne 0 ]]; then
    echo '[build] WARNING: make install returned non-zero, but all custom ath9k_hw params are visible; continuing'
  fi
} 2>&1 | tee \"\$log\"
"
}

deploy_patch_and_build_nodes() {
  local nodes="${1:-}" patch_file="${2:-$PATCH_FILE}" n
  patch_file="$(script_path "$patch_file")"
  if [[ -z "$nodes" ]]; then nodes="$(all_nodes_csv)" || return 1; fi
  for n in $(split_csv "$nodes"); do
    apply_patch_on_node "$n" "$patch_file" || return 1
    build_driver_on_node "$n" || return 1
  done
}

load_driver_on_node() {
  local node="$1" opts="${2:-}"
  echo "[driver] $node ath9k_hw opts: ${opts:-<none>}"
  node_bash "$node" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/setup'
dmesg_start=\$(dmesg 2>/dev/null | wc -l || echo 0)
requested_opts=\"$opts\"
supported_params=\$(modinfo ath9k_hw 2>/dev/null | sed -n 's/^parm:[[:space:]]*\\([^: ]*\\).*/\\1/p' || true)
effective_opts=''
for kv in \$requested_opts; do
  key=\"\${kv%%=*}\"
  val=\"\${kv#*=}\"
  if printf '%s\\n' \"\$supported_params\" | grep -qx \"\$key\"; then
    effective_opts=\"\$effective_opts \$kv\"
  elif [[ \"\$val\" == \"0\" || \"\$val\" == \"false\" || \"\$val\" == \"False\" || \"\$val\" == \"N\" || \"\$val\" == \"n\" ]]; then
    echo \"[driver] WARNING: ath9k_hw does not support zero/default option '\$key'; dropping it before modprobe\" >&2
  else
    echo \"[driver] ERROR: ath9k_hw does not support requested option '\$key=\$val'\" >&2
    echo '[driver] Run Setup -> deploy patch/build on this node, then reload drivers.' >&2
    echo '[driver] Supported ath9k_hw params:' >&2
    printf '  %s\\n' \$supported_params >&2
    exit 1
  fi
done
killall hostapd 2>/dev/null || true
ip link set wlan0 down 2>/dev/null || true
modprobe -r ath9k ath9k_common ath9k_hw ath mac80211 cfg80211 2>/dev/null || true
modprobe ath9k_hw \$effective_opts
modprobe ath9k
{
  date
  echo 'requested ath9k_hw opts: $opts'
  echo \"effective ath9k_hw opts:\$effective_opts\"
  lsmod | grep ath9k || true
  for p in /sys/module/ath9k_hw/parameters/*; do [[ -f \"\$p\" ]] && echo \"\$(basename \"\$p\")=\$(cat \"\$p\")\"; done
  echo '[dmesg] new ath9k-related lines from this load only:'
  dmesg 2>/dev/null | tail -n +\$((dmesg_start + 1)) | grep -i 'ath9k\|selfish\|txop\|backoff\|force' || true
} | tee '$NODE_LOG_DIR/setup/${node}_load_driver_$(join_opts_tag "$opts").log'
"
}

start_ap() {
  require_nodes_config || return 1
  local mode="${1:-n}" ap_node="${2:-$AP_NODE}" ap_ip="${3:-$AP_IP}" ssid="${4:-$SSID}" # mode: n or g
  local ieee80211n=1 hw_mode=g
  if [[ "$mode" == "g" ]]; then ieee80211n=0; hw_mode=g; fi
  node_bash "$ap_node" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/setup'
if ! command -v hostapd >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt install -y hostapd
fi
cat > /root/ece436_ap.conf <<EOF_AP
interface=wlan0
driver=nl80211
ssid=$ssid
hw_mode=$hw_mode
channel=$CHANNEL
ieee80211n=$ieee80211n
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
EOF_AP
ip link set wlan0 down 2>/dev/null || true
ifconfig wlan0 '$ap_ip' up
killall hostapd 2>/dev/null || true
nohup hostapd -dd /root/ece436_ap.conf > '$NODE_LOG_DIR/setup/${ap_node}_hostapd_${mode}.log' 2>&1 & echo \$! > '$NODE_LOG_DIR/setup/${ap_node}_hostapd.pid'
sleep 2
cat '$NODE_LOG_DIR/setup/${ap_node}_hostapd.pid'
tail -40 '$NODE_LOG_DIR/setup/${ap_node}_hostapd_${mode}.log' || true
"
}

connect_sta() {
  require_nodes_config || return 1
  local node="$1" ip="$2" ssid="${3:-$SSID}" ap_ip="${4:-$AP_IP}"
  node_bash "$node" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/setup'
ip link set wlan0 down 2>/dev/null || true
ifconfig wlan0 '$ip' up
iw dev wlan0 disconnect 2>/dev/null || true
iw dev wlan0 connect '$ssid' || true
sleep 3
{
  date
  ip addr show wlan0
  iw dev wlan0 link || true
  ping -c 5 '$ap_ip' || true
} | tee '$NODE_LOG_DIR/setup/${node}_connect_${ssid}.log'
"
}

snapshot_experiment_state() {
  local prefix="$1" nodes="$2" conf_b64 n opts_tag baseline_opts
  baseline_opts="selfish_mode=0 disable_backoff=0 chanel_idle=0 selfish_txop_us=0"
  conf_b64="$(config_content | base64 -w0)"
  for n in $(split_csv "$nodes"); do
    [[ -n "$n" ]] || continue
    if [[ "$n" == "$FAIR_NODE" ]]; then
      opts_tag="$(join_opts_tag "$FAIR_DRIVER_OPTS")"
    elif [[ "$n" == "$UNFAIR_NODE" ]]; then
      opts_tag="$(join_opts_tag "$UNFAIR_DRIVER_OPTS")"
    else
      opts_tag="$(join_opts_tag "$baseline_opts")"
    fi
    node_bash "$n" "
set -euo pipefail
exp_dir='$NODE_LOG_DIR/$prefix'
setup_src='$NODE_LOG_DIR/setup'
setup_dst=\"\$exp_dir/setup\"
mkdir -p \"\$setup_dst\"
printf '%s' '$conf_b64' | base64 -d > \"\$exp_dir/experiment.conf\"
copy_if_exists() { [[ -e \"\$1\" ]] && cp -a \"\$1\" \"\$setup_dst/\" || true; }
latest_backports=\$(ls -t \"\$setup_src\"/${n}_backports_build_*.log 2>/dev/null | head -n 1 || true)
[[ -n \"\$latest_backports\" ]] && copy_if_exists \"\$latest_backports\"
copy_if_exists \"\$setup_src/${n}_load_driver_${opts_tag}.log\"
for f in \"\$setup_src\"/${n}_hostapd*.log \"\$setup_src\"/${n}_hostapd.pid \"\$setup_src\"/${n}_connect_*.log; do
  copy_if_exists \"\$f\"
done
"
  done
}

prepare_topology() {
  require_nodes_config || return 1
  local unfair_opts="$1" fair_opts="$2" mode="${3:-n}"
  load_driver_on_node "$AP_NODE" "selfish_mode=0 disable_backoff=0 chanel_idle=0 selfish_txop_us=0" || return 1
  load_driver_on_node "$FAIR_NODE" "$fair_opts" || return 1
  load_driver_on_node "$UNFAIR_NODE" "$unfair_opts" || return 1
  start_ap "$mode" "$AP_NODE" "$AP_IP" "$SSID" || return 1
  connect_sta "$FAIR_NODE" "$FAIR_IP" "$SSID" "$AP_IP" || return 1
  connect_sta "$UNFAIR_NODE" "$UNFAIR_IP" "$SSID" "$AP_IP" || return 1
}

prepare_two_ap_topology() {
  require_two_ap_nodes_config || return 1
  local unfair_opts="$1" fair_opts="$2" mode="${3:-n}"
  load_driver_on_node "$AP_NODE" "selfish_mode=0 disable_backoff=0 chanel_idle=0 selfish_txop_us=0" || return 1
  load_driver_on_node "$AP2_NODE" "selfish_mode=0 disable_backoff=0 chanel_idle=0 selfish_txop_us=0" || return 1
  load_driver_on_node "$FAIR_NODE" "$fair_opts" || return 1
  load_driver_on_node "$UNFAIR_NODE" "$unfair_opts" || return 1
  start_ap "$mode" "$AP_NODE" "$AP_IP" "$SSID" || return 1
  start_ap "$mode" "$AP2_NODE" "$AP2_IP" "$AP2_SSID" || return 1
  connect_sta "$FAIR_NODE" "$FAIR_IP" "$SSID" "$AP_IP" || return 1
  connect_sta "$UNFAIR_NODE" "$UNFAIR_IP" "$AP2_SSID" "$AP2_IP" || return 1
}

prepare_single_topology() {
  require_nodes_config || return 1
  local which="$1" sta_node sta_ip sta_opts mode="${2:-n}"
  case "$which" in
    fair)
      sta_node="$FAIR_NODE"; sta_ip="$FAIR_IP"; sta_opts="$FAIR_DRIVER_OPTS"
      ;;
    unfair)
      sta_node="$UNFAIR_NODE"; sta_ip="$UNFAIR_IP"; sta_opts="$UNFAIR_DRIVER_OPTS"
      ;;
    *)
      echo "Unknown STA role: $which" >&2
      return 1
      ;;
  esac
  load_driver_on_node "$AP_NODE" "selfish_mode=0 disable_backoff=0 chanel_idle=0 selfish_txop_us=0" || return 1
  load_driver_on_node "$sta_node" "$sta_opts" || return 1
  start_ap "$mode" "$AP_NODE" "$AP_IP" "$SSID" || return 1
  connect_sta "$sta_node" "$sta_ip" "$SSID" "$AP_IP" || return 1
}

iperf_server() {
  local node="$1" proto="$2" port="$3" label="$4"
  local udpflag="-u"; [[ "$proto" == "tcp" ]] && udpflag=""
  node_bash "$node" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/$label'
if ! command -v iperf >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt install -y iperf
fi
if [[ -f '$NODE_LOG_DIR/iperf_server_${port}.pid' ]]; then
  old_pid=\$(cat '$NODE_LOG_DIR/iperf_server_${port}.pid' 2>/dev/null || true)
  [[ -n \"\${old_pid:-}\" ]] && kill \"\$old_pid\" 2>/dev/null || true
fi
nohup iperf -s $udpflag -p '$port' -i 1 > '$NODE_LOG_DIR/$label/${node}_iperf_${proto}_server_p${port}.log' 2>&1 & echo \$! > '$NODE_LOG_DIR/iperf_server_${port}.pid'
sleep 1
cat '$NODE_LOG_DIR/iperf_server_${port}.pid'
tail -5 '$NODE_LOG_DIR/$label/${node}_iperf_${proto}_server_p${port}.log' || true
"
}

iperf_client() {
  local node="$1" proto="$2" server_ip="$3" rate="$4" duration="$5" port="$6" label="$7" tag="$8"
  local cmd
  if [[ "$proto" == "tcp" ]]; then
    cmd="iperf -c '$server_ip' -p '$port' -t '$duration' -i 1"
  else
    cmd="iperf -c '$server_ip' -u -p '$port' -b '$rate' -t '$duration' -i 1"
  fi
  node_bash "$node" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/$label'
if ! command -v iperf >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt install -y iperf
fi
{
  date
  echo '$cmd'
  $cmd
} 2>&1 | tee '$NODE_LOG_DIR/$label/${node}_iperf_${proto}_client_${tag}_to_${server_ip}_$(rate_tag "$rate")_${duration}s_p${port}.log'
"
}

run_two_sta_once() {
  require_nodes_config || return 1
  local proto="$1" fair_rate="$2" unfair_rate="$3" duration="$4" label="$5" fair_lead_seconds="${6:-$DUAL_FAIR_LEAD_SECONDS}"
  if ! [[ "$fair_lead_seconds" =~ ^[0-9]+$ ]]; then
    echo "Invalid fair lead delay: $fair_lead_seconds (must be non-negative integer seconds)" >&2
    return 1
  fi
  iperf_server "$AP_NODE" "$proto" "$FAIR_PORT" "$label" || return 1
  iperf_server "$AP_NODE" "$proto" "$UNFAIR_PORT" "$label" || return 1
  sleep 2
  echo "[dual] starting fair STA first: node=$FAIR_NODE rate=$fair_rate duration=${duration}s"
  iperf_client "$FAIR_NODE" "$proto" "$AP_IP" "$fair_rate" "$duration" "$FAIR_PORT" "$label" "fair" &
  local fair_pid=$!
  if (( fair_lead_seconds > 0 )); then
    echo "[dual] waiting ${fair_lead_seconds}s before starting unfair STA"
    sleep "$fair_lead_seconds"
  fi
  echo "[dual] starting unfair STA: node=$UNFAIR_NODE rate=$unfair_rate duration=${duration}s"
  iperf_client "$UNFAIR_NODE" "$proto" "$AP_IP" "$unfair_rate" "$duration" "$UNFAIR_PORT" "$label" "unfair" &
  local unfair_pid=$!
  local rc1=0 rc2=0
  wait "$fair_pid" || rc1=$?
  wait "$unfair_pid" || rc2=$?
  [[ "$rc1" -eq 0 && "$rc2" -eq 0 ]]
}

run_two_ap_once() {
  require_two_ap_nodes_config || return 1
  local proto="$1" fair_rate="$2" unfair_rate="$3" duration="$4" label="$5" fair_lead_seconds="${6:-$DUAL_FAIR_LEAD_SECONDS}"
  if ! [[ "$fair_lead_seconds" =~ ^[0-9]+$ ]]; then
    echo "Invalid fair lead delay: $fair_lead_seconds (must be non-negative integer seconds)" >&2
    return 1
  fi
  iperf_server "$AP_NODE" "$proto" "$FAIR_PORT" "$label" || return 1
  iperf_server "$AP2_NODE" "$proto" "$UNFAIR_PORT" "$label" || return 1
  sleep 2
  echo "[two-ap] starting fair STA toward AP1: node=$FAIR_NODE ap=$AP_NODE ip=$AP_IP rate=$fair_rate duration=${duration}s"
  iperf_client "$FAIR_NODE" "$proto" "$AP_IP" "$fair_rate" "$duration" "$FAIR_PORT" "$label" "fair" &
  local fair_pid=$!
  if (( fair_lead_seconds > 0 )); then
    echo "[two-ap] waiting ${fair_lead_seconds}s before starting unfair STA toward AP2"
    sleep "$fair_lead_seconds"
  fi
  echo "[two-ap] starting unfair STA toward AP2: node=$UNFAIR_NODE ap=$AP2_NODE ip=$AP2_IP rate=$unfair_rate duration=${duration}s"
  iperf_client "$UNFAIR_NODE" "$proto" "$AP2_IP" "$unfair_rate" "$duration" "$UNFAIR_PORT" "$label" "unfair" &
  local unfair_pid=$!
  local rc1=0 rc2=0
  wait "$fair_pid" || rc1=$?
  wait "$unfair_pid" || rc2=$?
  [[ "$rc1" -eq 0 && "$rc2" -eq 0 ]]
}

run_single_sta_sweep() {
  require_nodes_config || return 1
  local which="$1" proto="$2" rates="$3" duration="$4" prefix="$5"
  local node ip port tag rate label
  if [[ "$which" == "fair" ]]; then node="$FAIR_NODE"; port="$FAIR_PORT"; tag="fair"; else node="$UNFAIR_NODE"; port="$UNFAIR_PORT"; tag="unfair"; fi
  for rate in $(split_csv "$rates"); do
    label="${prefix}/${tag}_$(rate_tag "$rate")_$(ts)_proto_${proto}"
    iperf_server "$AP_NODE" "$proto" "$port" "$label" || return 1
    sleep 2
    iperf_client "$node" "$proto" "$AP_IP" "$rate" "$duration" "$port" "$label" "$tag" || return 1
  done
}

run_single_sta_experiment() {
  local which="$1" proto wifi_mode rates duration prefix nodes
  proto=$(prompt_protocol)
  wifi_mode=$(prompt_wifi_mode)
  rates=$(prompt_default "Rates comma-separated" "$RATES")
  duration=$(prompt_default "Duration seconds per rate" "$DURATION")
  RATES="$rates"; DURATION="$duration"
  prefix=$(prompt_default "Log prefix" "${which}_only_${proto}_11${wifi_mode}_$(ts)")
  if prompt_yes_no "Prepare topology/load drivers before test?" "y"; then
    prepare_single_topology "$which" "$wifi_mode" || return 1
  fi
  if [[ "$which" == "fair" ]]; then nodes="$AP_NODE,$FAIR_NODE"; else nodes="$AP_NODE,$UNFAIR_NODE"; fi
  snapshot_experiment_state "$prefix" "$nodes" || return 1
  run_single_sta_sweep "$which" "$proto" "$rates" "$duration" "$prefix"
}

ask_fixed_rate_plan() {
  # Prints mode|fixed_node|fixed_rate|sweep_rates
  local choice fixed_rate sweep_rates
  choice=$(prompt_choice "Fixed iperf offered-rate mode:" \
    "No fixed STA: both STAs sweep/use same rate list" \
    "Unfair STA fixed, fair STA sweeps" \
    "Fair STA fixed, unfair STA sweeps" \
    "Both STAs fixed at explicit rates")
  case "$choice" in
    1)
      sweep_rates=$(prompt_default "Rates comma-separated" "$RATES")
      printf 'none||%s|%s\n' "" "$sweep_rates"
      ;;
    2)
      fixed_rate=$(prompt_default "Fixed rate for unfair STA" "$FIXED_RATE_DEFAULT")
      sweep_rates=$(prompt_default "Sweep rates for fair STA" "$RATES")
      printf 'unfair|%s|%s|%s\n' "$UNFAIR_NODE" "$fixed_rate" "$sweep_rates"
      ;;
    3)
      fixed_rate=$(prompt_default "Fixed rate for fair STA" "$FIXED_RATE_DEFAULT")
      sweep_rates=$(prompt_default "Sweep rates for unfair STA" "$RATES")
      printf 'fair|%s|%s|%s\n' "$FAIR_NODE" "$fixed_rate" "$sweep_rates"
      ;;
    4)
      local fair_fixed unfair_fixed
      fair_fixed=$(prompt_default "Fixed rate for fair STA" "$FIXED_RATE_DEFAULT")
      unfair_fixed=$(prompt_default "Fixed rate for unfair STA" "$FIXED_RATE_DEFAULT")
      printf 'both|both|%s,%s|%s\n' "$fair_fixed" "$unfair_fixed" "single"
      ;;
  esac
}

run_dual_sta_experiment() {
  local proto wifi_mode
  proto=$(prompt_protocol)
  wifi_mode=$(prompt_wifi_mode)
  run_dual_test_with_plan "fair_unfair_${proto}_11${wifi_mode}" "$proto" "$FAIR_DRIVER_OPTS" "$UNFAIR_DRIVER_OPTS" "$wifi_mode"
}

run_two_ap_experiment() {
  local proto wifi_mode
  proto=$(prompt_protocol)
  wifi_mode=$(prompt_wifi_mode)
  run_two_ap_test_with_plan "two_ap_fair_unfair_${proto}_11${wifi_mode}" "$proto" "$FAIR_DRIVER_OPTS" "$UNFAIR_DRIVER_OPTS" "$wifi_mode"
}

run_dual_plan() {
  local test_name="$1" proto="$2" fair_opts="$3" unfair_opts="$4" wifi_mode="$5" topology_fn="$6" run_once_fn="$7"
  local duration prefix plan mode fixed_node fixed_rate sweep_rates rate fair_rate unfair_rate label fair_lead_seconds
  duration=$(prompt_default "Duration seconds per run" "$DURATION")
  fair_lead_seconds=$(prompt_default "Seconds to start fair STA before unfair STA" "$DUAL_FAIR_LEAD_SECONDS")
  DURATION="$duration"; DUAL_FAIR_LEAD_SECONDS="$fair_lead_seconds"
  if ! [[ "$fair_lead_seconds" =~ ^[0-9]+$ ]]; then
    echo "Invalid fair lead delay: $fair_lead_seconds (must be non-negative integer seconds)" >&2
    return 1
  fi
  prefix=$(prompt_default "Log prefix" "${test_name}_$(ts)")
  IFS='|' read -r mode fixed_node fixed_rate sweep_rates <<<"$(ask_fixed_rate_plan)"
  [[ -n "$sweep_rates" ]] && RATES="$sweep_rates"
  if prompt_yes_no "Prepare topology/load drivers before test?" "y"; then
    "$topology_fn" "$unfair_opts" "$fair_opts" "$wifi_mode" || return 1
  fi
  if [[ "$topology_fn" == "prepare_two_ap_topology" ]]; then
    snapshot_experiment_state "$prefix" "$AP_NODE,$AP2_NODE,$FAIR_NODE,$UNFAIR_NODE" || return 1
  else
    snapshot_experiment_state "$prefix" "$AP_NODE,$FAIR_NODE,$UNFAIR_NODE" || return 1
  fi
  # Keep driver options out of log paths. The collected experiment.conf records
  # FAIR_DRIVER_OPTS/UNFAIR_DRIVER_OPTS for the whole experiment.
  case "$mode" in
    none)
      for rate in $(split_csv "$sweep_rates"); do
        label="${prefix}/unfair_$(rate_tag "$rate")_fair_$(rate_tag "$rate")_$(ts)_proto_${proto}_fairlead_${fair_lead_seconds}s"
        "$run_once_fn" "$proto" "$rate" "$rate" "$duration" "$label" "$fair_lead_seconds" || return 1
      done
      ;;
    unfair)
      for rate in $(split_csv "$sweep_rates"); do
        label="${prefix}/unfair_$(rate_tag "$fixed_rate")_fair_$(rate_tag "$rate")_$(ts)_proto_${proto}_fairlead_${fair_lead_seconds}s"
        "$run_once_fn" "$proto" "$rate" "$fixed_rate" "$duration" "$label" "$fair_lead_seconds" || return 1
      done
      ;;
    fair)
      for rate in $(split_csv "$sweep_rates"); do
        label="${prefix}/unfair_$(rate_tag "$rate")_fair_$(rate_tag "$fixed_rate")_$(ts)_proto_${proto}_fairlead_${fair_lead_seconds}s"
        "$run_once_fn" "$proto" "$fixed_rate" "$rate" "$duration" "$label" "$fair_lead_seconds" || return 1
      done
      ;;
    both)
      IFS=',' read -r fair_rate unfair_rate <<<"$fixed_rate"
      label="${prefix}/unfair_$(rate_tag "$unfair_rate")_fair_$(rate_tag "$fair_rate")_$(ts)_proto_${proto}_fairlead_${fair_lead_seconds}s"
      "$run_once_fn" "$proto" "$fair_rate" "$unfair_rate" "$duration" "$label" "$fair_lead_seconds" || return 1
      ;;
  esac
}

run_dual_test_with_plan() {
  run_dual_plan "$1" "$2" "$3" "$4" "$5" prepare_topology run_two_sta_once
}

run_two_ap_test_with_plan() {
  run_dual_plan "$1" "$2" "$3" "$4" "$5" prepare_two_ap_topology run_two_ap_once
}

# ---------- Results ----------
organize_collected_results() {
  local out="$1" raw="$2" fetch_stamp="$3"
  python3 - "$out" "$raw" "$fetch_stamp" "$AP_NODE" "$AP2_NODE" "$FAIR_NODE" "$UNFAIR_NODE" "$FAIR_PORT" "$UNFAIR_PORT" <<'PY'
import re, shutil, sys
from pathlib import Path
out=Path(sys.argv[1]); raw=Path(sys.argv[2]); fetch_stamp=sys.argv[3]
ap_node, ap2_node, fair_node, unfair_node = sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
fair_port, unfair_port = sys.argv[8], sys.argv[9]
node_roles={ap_node:f"AP_{ap_node}", fair_node:f"fair_{fair_node}", unfair_node:f"unfair_{unfair_node}"}
if ap2_node:
    node_roles[ap2_node]=f"AP2_{ap2_node}"

def safe(s):
    s=re.sub(r'[^A-Za-z0-9_.-]+','_',str(s)).strip('_')
    return s or 'unknown'

def unique(path: Path) -> Path:
    if not path.exists():
        return path
    stem, suffix = path.stem, path.suffix
    i=2
    while True:
        cand=path.with_name(f"{stem}_{i}{suffix}")
        if not cand.exists():
            return cand
        i+=1

def split_label(label_parts):
    # Expected remote layout for new runs:
    #   <experiment_name>_<timestamp>/unfair_<rate>_fair_<rate>_<timestamp>_proto_...
    if len(label_parts) < 2:
        return None
    return safe(label_parts[0]), label_parts[1], '/'.join(label_parts)

def pair_from_label(label):
    m=re.search(r'unfair_([^_/]+)_fair_([^_/]+)', label)
    if not m:
        return 'unknown', 'unknown'
    return safe(m.group(1)), safe(m.group(2))

def stamp_from(*texts):
    for text in texts:
        m=re.search(r'(20\d{6}_\d{6}(?:_[0-9]{2})?)', text or '')
        if m: return m.group(1)
    return fetch_stamp

def file_port(name):
    m=re.search(r'_p(\d+)\.log$', name)
    return m.group(1) if m else ''

experiments=set()
for node_dir in sorted([p for p in raw.iterdir() if p.is_dir()]):
    node=node_dir.name
    role_dir=node_roles.get(node, node)
    log_files=[p for p in node_dir.rglob('*.log') if p.is_file()]
    node_experiments=set()
    for f in log_files:
        rel=f.relative_to(node_dir)
        if rel.parts and rel.parts[0] == 'setup':
            continue
        if 'iperf' not in f.name:
            continue
        parsed = split_label(rel.parts[:-1])
        if parsed is None:
            continue
        exp, _, _ = parsed
        node_experiments.add(exp); experiments.add(exp)
    if not node_experiments:
        node_experiments.add(f"collected_{fetch_stamp}"); experiments.update(node_experiments)
    for exp in node_experiments:
        exp_src=node_dir/exp
        conf=exp_src/'experiment.conf'
        if conf.exists() and not (out/exp/'experiment.conf').exists():
            (out/exp).mkdir(parents=True, exist_ok=True)
            shutil.copy2(conf, out/exp/'experiment.conf')
        setup=exp_src/'setup'
        if setup.exists():
            dest=out/exp/role_dir/'setup'
            dest.mkdir(parents=True, exist_ok=True)
            for item in setup.iterdir():
                target=unique(dest/item.name)
                if item.is_dir(): shutil.copytree(item, target)
                else: shutil.copy2(item, target)
    for f in log_files:
        rel=f.relative_to(node_dir)
        if rel.parts and rel.parts[0] == 'setup':
            continue
        if 'iperf' not in f.name:
            continue
        parsed = split_label(rel.parts[:-1])
        if parsed is None:
            continue
        exp, run_label, full_label = parsed
        unfair_rate, fair_rate = pair_from_label(full_label)
        run_stamp=stamp_from(run_label, full_label, f.name)
        port=file_port(f.name)
        dest_dir=out/exp/role_dir
        dest_dir.mkdir(parents=True, exist_ok=True)
        if node == fair_node:
            new_name=f"{fair_rate}_{run_stamp}.log"
        elif node == unfair_node:
            new_name=f"{unfair_rate}_{run_stamp}.log"
        elif node == ap_node or node == ap2_node:
            suffix=f"_p{port}" if port else ''
            new_name=f"unfair_{unfair_rate}_fair_{fair_rate}{suffix}_{run_stamp}.log"
        else:
            new_name=f"{safe(f.stem)}_{run_stamp}.log"
        shutil.copy2(f, unique(dest_dir/new_name))
for exp in sorted(experiments):
    (out/exp).mkdir(parents=True, exist_ok=True)
print(f"Organized {len(experiments)} experiment(s) under {out}")
PY
}

fetch_results() {
  local out="${1:-$LOCAL_RESULTS_DIR/collected_$(ts)}" nodes="${2:-}"
  out="$(script_path "$out")"
  if [[ -z "$nodes" ]]; then nodes="$(all_nodes_csv)" || return 1; fi
  mkdir -p "$out"
  local stamp n raw
  stamp="$(ts)"
  raw="$out/.raw_${stamp}"
  mkdir -p "$raw"
  for n in $(split_csv "$nodes"); do
    echo "[fetch] $n -> $raw/$n"
    node_bash "$n" "
set -euo pipefail
if [[ -d '$NODE_LOG_DIR' ]]; then
  tar czf '/tmp/${n}_ece436_logs_${stamp}.tar.gz' -C '$NODE_LOG_DIR' .
else
  mkdir -p /tmp/empty_ece436_logs
  tar czf '/tmp/${n}_ece436_logs_${stamp}.tar.gz' -C /tmp/empty_ece436_logs .
fi
"
    gw "scp root@'$n':'/tmp/${n}_ece436_logs_${stamp}.tar.gz' '/tmp/${n}_ece436_logs_${stamp}.tar.gz'"
    scp "${SSH_OPTS[@]}" "$(gateway_target):/tmp/${n}_ece436_logs_${stamp}.tar.gz" "$raw/"
    mkdir -p "$raw/$n"
    tar xzf "$raw/${n}_ece436_logs_${stamp}.tar.gz" -C "$raw/$n"
  done
  organize_collected_results "$out" "$raw" "$stamp"
  rm -rf "$raw"
  local exp
  for exp in "$out"/*; do
    [[ -d "$exp" ]] || continue
    if [[ ! -f "$exp/experiment.conf" ]]; then
      export_config "$exp/experiment.conf"
    fi
    parse_results "$exp" "$exp/summary.csv"
    plot_results "$exp" "$exp/summary.csv" "$PLOTS_DIR/$(basename "$exp")"
  done
  echo "Collected logs under: $out"
  echo "Plots under: $PLOTS_DIR"
}

parse_results() {
  local indir="$1" out="${2:-$indir/summary.csv}"
  [[ -d "$indir" ]] || { echo "Input directory not found: $indir" >&2; return 1; }
  python3 - "$indir" "$out" <<'PY'
import csv, re, sys
from pathlib import Path
indir = Path(sys.argv[1])
out = Path(sys.argv[2])
bw_re = re.compile(r'\[\s*\d+\]\s+(?P<interval>\d+(?:\.\d+)?\s*-\s*\d+(?:\.\d+)?)\s+sec\s+(?P<transfer>[\d.]+)\s+(?P<transfer_unit>[KMG]?Bytes)\s+(?P<bw>[\d.]+)\s+(?P<bw_unit>[KMG]?bits/sec)(?:\s+(?P<jitter>[\d.]+)\s+ms\s+(?P<lost>\d+)\s*/\s*(?P<total>\d+)\s*\((?P<loss_pct>[\d.]+)%\))?')
cmd_re = re.compile(r'iperf\s+-c\s+(?P<server_ip>\S+).*?(?:-u\s+)?-p\s+(?P<port>\d+)(?:.*?-b\s+(?P<rate>\S+))?.*?-t\s+(?P<duration>\S+)')

def pair_from_rel(rel):
    text=str(rel)
    m=re.search(r'unfair_([^_/]+)_fair_([^_/]+)', text)
    if m: return m.group(1), m.group(2)
    return '', ''

def run_stamp_from_name(name):
    m=re.search(r'(20\d{6}_\d{6})', name)
    return m.group(1) if m else ''

def parse_log_start_time(lines):
    # iperf_client() writes `date` before the command, e.g.
    # `Sun Jun 28 14:19:41 EEST 2026`.  Ignore timezone name because Python
    # does not reliably know EEST in all environments; all node logs use the
    # same local wall clock for one run.
    months={'Jan':1,'Feb':2,'Mar':3,'Apr':4,'May':5,'Jun':6,'Jul':7,'Aug':8,'Sep':9,'Oct':10,'Nov':11,'Dec':12}
    for ln in lines[:8]:
        parts=ln.split()
        if len(parts) >= 6 and parts[1] in months and re.match(r'\d{1,2}:\d{2}:\d{2}$', parts[3]):
            try:
                import datetime as _dt
                hh,mm,ss=map(int, parts[3].split(':'))
                return _dt.datetime(int(parts[5]), months[parts[1]], int(parts[2]), hh, mm, ss)
            except Exception:
                return None
    return None

file_infos=[]
client_starts={}
for f in sorted(indir.rglob('*.log')):
    if not f.is_file() or 'setup' in f.parts:
        continue
    text=f.read_text(errors='replace')
    lines=[ln.strip() for ln in text.splitlines() if ln.strip()]
    matches=[]
    for ln in lines:
        m=bw_re.search(ln)
        if m: matches.append((ln,m))
    if not matches: continue
    rel=f.relative_to(indir)
    parts=rel.parts
    node=parts[0] if parts else ''
    label=indir.name
    unfair_rate, fair_rate = pair_from_rel(rel)
    name=f.name
    role='server' if '_server_' in name or node.startswith(('AP_','AP2_')) else 'client' if '_client_' in name or node.startswith(('fair_','unfair_')) else 'unknown'
    proto='tcp' if '_tcp_' in name else 'udp' if '_udp_' in name else 'unknown'
    port=''; offered_rate=''; duration=''; server_ip=''
    pm=re.search(r'_p(\d+)', name)
    if pm: port=pm.group(1)
    for l2 in lines:
        cm=cmd_re.search(l2)
        if cm:
            server_ip=cm.group('server_ip'); port=cm.group('port') or port; offered_rate=cm.group('rate') or ''; duration=cm.group('duration') or ''
            break
    if not offered_rate:
        cm=re.match(r'([^_]+)_20\d{6}_\d{6}\.log$', name)
        if cm and node.startswith(('fair_','unfair_')): offered_rate=cm.group(1)
    run_stamp=run_stamp_from_name(name)
    start_time=parse_log_start_time(lines) if role == 'client' else None
    file_infos.append({
        'matches': matches, 'rel': rel, 'node': node, 'label': label, 'role': role, 'proto': proto, 'port': port,
        'fair_rate': fair_rate, 'unfair_rate': unfair_rate, 'offered_rate': offered_rate, 'duration': duration,
        'server_ip': server_ip, 'run_stamp': run_stamp, 'start_time': start_time,
    })
    if role == 'client' and port and run_stamp and start_time is not None:
        client_starts[(run_stamp, port)] = start_time

min_start_by_run={}
for (run_stamp, _port), start_time in client_starts.items():
    cur=min_start_by_run.get(run_stamp)
    if cur is None or start_time < cur:
        min_start_by_run[run_stamp] = start_time

rows=[]
for info in file_infos:
    start_time = info['start_time']
    if start_time is None and info['port'] and info['run_stamp']:
        start_time = client_starts.get((info['run_stamp'], info['port']))
    start_offset=''
    if start_time is not None and info['run_stamp'] in min_start_by_run:
        start_offset = f"{(start_time - min_start_by_run[info['run_stamp']]).total_seconds():.3f}"
    for idx,(ln,m) in enumerate(info['matches']):
        rows.append({
            'label': info['label'], 'node': info['node'], 'role': info['role'], 'proto': info['proto'], 'port': info['port'],
            'fair_rate': info['fair_rate'], 'unfair_rate': info['unfair_rate'],
            'offered_rate': info['offered_rate'], 'duration_s': info['duration'], 'server_ip': info['server_ip'],
            'run_stamp': info['run_stamp'], 'start_offset_s': start_offset,
            'interval_s': m.group('interval').replace(' ', ''), 'is_final': '1' if idx == len(info['matches'])-1 else '0',
            'transfer': m.group('transfer'), 'transfer_unit': m.group('transfer_unit'),
            'bandwidth': m.group('bw'), 'bandwidth_unit': m.group('bw_unit'),
            'jitter_ms': m.group('jitter') or '', 'lost': m.group('lost') or '', 'total': m.group('total') or '', 'loss_pct': m.group('loss_pct') or '',
            'source_file': str(info['rel']), 'summary_line': ln,
        })
out.parent.mkdir(parents=True, exist_ok=True)
fields=['label','node','role','proto','port','fair_rate','unfair_rate','offered_rate','duration_s','server_ip','run_stamp','start_offset_s','interval_s','is_final','transfer','transfer_unit','bandwidth','bandwidth_unit','jitter_ms','lost','total','loss_pct','source_file','summary_line']
with out.open('w', newline='') as fh:
    w=csv.DictWriter(fh, fieldnames=fields); w.writeheader(); w.writerows(rows)
print(f'Wrote {len(rows)} rows to {out}')
print('Final receiver/server rows:')
for r in rows:
    if r['role']=='server' and r['is_final']=='1':
        loss = f" loss={r['lost']}/{r['total']} ({r['loss_pct']}%)" if r['lost'] else ''
        pair = f" unfair={r['unfair_rate']} fair={r['fair_rate']}" if r['unfair_rate'] or r['fair_rate'] else ''
        offset = f" start_offset={r['start_offset_s']}s" if r.get('start_offset_s') else ''
        print(f"{r['label']}{pair} {r['node']} {r['proto']} port={r['port']}{offset} bw={r['bandwidth']} {r['bandwidth_unit']}{loss}")
PY
}

plot_results() {
  local indir="$1" csv="${2:-$indir/summary.csv}" outdir="${3:-$PLOTS_DIR/$(basename "$indir")}" 
  [[ -f "$csv" ]] || parse_results "$indir" "$csv"
  python3 - "$csv" "$outdir" "$FAIR_PORT" "$UNFAIR_PORT" <<'PY'
import csv, re, sys
from collections import defaultdict
from pathlib import Path
csv_path=Path(sys.argv[1]); outdir=Path(sys.argv[2]); fair_port=sys.argv[3]; unfair_port=sys.argv[4]
outdir.mkdir(parents=True, exist_ok=True)
try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
except Exception:
    plt = None

def write_basic_png(path, title, label_series):
    # Pure-stdlib fallback for environments without matplotlib.  It keeps the
    # same PNG filename and draws the actual time-shifted series instead of a
    # placeholder, so old PNGs are not left stale.
    import struct, zlib
    W,H=1000,500; L,R,T,B=70,30,35,55
    img=bytearray([255]*(W*H*3))
    def pix(x,y,c):
        if 0 <= x < W and 0 <= y < H:
            i=(y*W+x)*3; img[i:i+3]=bytes(c)
    def line(x0,y0,x1,y1,c):
        x0=int(round(x0)); y0=int(round(y0)); x1=int(round(x1)); y1=int(round(y1))
        dx=abs(x1-x0); sx=1 if x0<x1 else -1; dy=-abs(y1-y0); sy=1 if y0<y1 else -1; err=dx+dy
        while True:
            for ox in (-1,0,1):
                for oy in (-1,0,1): pix(x0+ox,y0+oy,c)
            if x0==x1 and y0==y1: break
            e2=2*err
            if e2>=dy: err+=dy; x0+=sx
            if e2<=dx: err+=dx; y0+=sy
    def rect(x0,y0,x1,y1,c):
        for y in range(max(0,int(y0)), min(H,int(y1)+1)):
            for x in range(max(0,int(x0)), min(W,int(x1)+1)): pix(x,y,c)
    allpts=[p for _name,pts in label_series for p in pts]
    if not allpts: return
    xmax=max(1.0, max(x for x,_ in allpts)); ymax=max(1.0, max(y for _,y in allpts))*1.10
    def sx(x): return L + (W-L-R)*x/xmax
    def sy(y): return H-B - (H-T-B)*y/ymax
    # grid + axes
    for k in range(6):
        x=L+(W-L-R)*k/5; line(x,T,x,H-B,(230,230,230))
        y=T+(H-T-B)*k/5; line(L,y,W-R,y,(230,230,230))
    line(L,T,L,H-B,(0,0,0)); line(L,H-B,W-R,H-B,(0,0,0))
    colors=[(31,119,180),(214,39,40),(44,160,44),(148,103,189)]
    for idx,(name,pts) in enumerate(label_series):
        c=colors[idx%len(colors)]
        last=None
        for x,y in pts:
            px,py=sx(x),sy(y)
            if last: line(last[0],last[1],px,py,c)
            rect(px-3,py-3,px+3,py+3,c)
            last=(px,py)
        # small color-box legend (text is available in matplotlib path only)
        rect(W-R-150, T+idx*18, W-R-135, T+idx*18+10, c)
    raw=b''.join(b'\x00'+bytes(img[y*W*3:(y+1)*W*3]) for y in range(H))
    def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
    png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',W,H,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw,9))+chunk(b'IEND',b'')
    path.write_bytes(png)

def bw_mbps(v,u):
    x=float(v)
    if u.startswith('K'): return x/1000.0
    if u.startswith('G'): return x*1000.0
    return x

def start_s(interval):
    m=re.match(r'([0-9.]+)-', interval or '')
    return float(m.group(1)) if m else 0.0

def row_offset_s(r):
    try:
        return float(r.get('start_offset_s') or 0.0)
    except Exception:
        return 0.0

def safe(s): return re.sub(r'[^A-Za-z0-9_.-]+','_',str(s)).strip('_') or 'unknown'
rows=list(csv.DictReader(csv_path.open()))
series=defaultdict(list)
for r in rows:
    if r.get('role')!='server' or r.get('is_final')=='1':
        continue
    unfair=safe(r.get('unfair_rate') or 'unknown')
    fair=safe(r.get('fair_rate') or 'unknown')
    try: y=bw_mbps(r['bandwidth'], r['bandwidth_unit'])
    except Exception: continue
    port=r.get('port','')
    name='fair_STA' if port == fair_port else 'unfair_STA' if port == unfair_port else f"server_port_{port}"
    series[(unfair, fair, name)].append((start_s(r['interval_s']) + row_offset_s(r), y))
pairs=sorted(set((u,f) for u,f,_ in series))
made=0
for unfair, fair in pairs:
    label_series=[]
    for (u,f,name),pts in sorted(series.items()):
        if u==unfair and f==fair and pts:
            label_series.append((name, sorted(pts)))
    if not label_series: continue
    title=f"unfair {unfair} / fair {fair}"
    path=outdir/f"unfair_{unfair}_fair_{fair}.png"
    if plt is None:
        write_basic_png(path, title, label_series)
    else:
        plt.figure(figsize=(10,5))
        for name,pts in label_series:
            xs=[p[0] for p in pts]; ys=[p[1] for p in pts]
            plt.plot(xs, ys, marker='o', linewidth=1.4, label=name)
        plt.title(title); plt.xlabel('time (s)'); plt.ylabel('receiver bandwidth (Mbit/s)')
        plt.grid(True, alpha=0.3); plt.legend(); plt.tight_layout(); plt.savefig(path, dpi=140); plt.close()
    print(path); made+=1
print(f'Wrote {made} plots to {outdir}')
PY
}

dry_run_results() {
  local stamp out raw exp old_ap old_fair old_unfair old_fair_port old_unfair_port
  stamp="$(ts)"
  out="${1:-$LOCAL_RESULTS_DIR/collected_${stamp}_dryrun}"
  out="$(script_path "$out")"
  exp="dryrun_${stamp}"
  raw="$out/.raw_${stamp}"
  old_ap="$AP_NODE"; old_fair="$FAIR_NODE"; old_unfair="$UNFAIR_NODE"
  old_fair_port="$FAIR_PORT"; old_unfair_port="$UNFAIR_PORT"
  AP_NODE="node900"; FAIR_NODE="node901"; UNFAIR_NODE="node902"
  FAIR_PORT="5004"; UNFAIR_PORT="5003"
  mkdir -p "$raw"
  python3 - "$raw" "$exp" "$stamp" "$AP_NODE" "$FAIR_NODE" "$UNFAIR_NODE" "$FAIR_PORT" "$UNFAIR_PORT" <<'PY'
import sys
from pathlib import Path
raw=Path(sys.argv[1]); exp=sys.argv[2]; stamp=sys.argv[3]
ap, fair, unfair = sys.argv[4], sys.argv[5], sys.argv[6]
fair_port, unfair_port = sys.argv[7], sys.argv[8]

def rate_num(rate):
    return float(rate.rstrip('Mm'))

def iperf_lines(mbps, seconds=6, jitter=0.12, loss=0, total_base=100):
    lines=[]
    for i in range(seconds):
        transfer=mbps/8.0
        lost=loss if i == seconds-1 else 0
        total=total_base*(i+1)
        lines.append(f"[  3] {i}.0- {i+1}.0 sec  {transfer:.2f} MBytes  {mbps:.2f} Mbits/sec {jitter:.3f} ms {lost}/{total} ({(100*lost/total):.1f}%)")
    lines.append(f"[  3] 0.0- {seconds}.0 sec  {mbps*seconds/8.0:.2f} MBytes  {mbps:.2f} Mbits/sec {jitter:.3f} ms {loss}/{total_base*seconds} ({(100*loss/(total_base*seconds)):.1f}%)")
    return '\n'.join(lines) + '\n'

def client_log(server_ip, port, rate, mbps, seconds=6):
    return f"Sun Jun 28 00:00:00 UTC 2026\niperf -c {server_ip} -u -p {port} -b {rate} -t {seconds} -i 1\n" + iperf_lines(mbps, seconds, jitter=0.05)

pairs=[('25M','5M'), ('25M','10M'), ('50M','10M')]
for node in (ap, fair, unfair):
    setup=raw/node/exp/'setup'
    setup.mkdir(parents=True, exist_ok=True)
    (raw/node/exp/'experiment.conf').write_text(f'# dry-run config snapshot for {exp}\nAP_NODE={ap}\nFAIR_NODE={fair}\nUNFAIR_NODE={unfair}\n')
    (setup/f'{node}_dryrun_setup.log').write_text(f'dummy setup for {node}\n')
for idx,(unfair_rate,fair_rate) in enumerate(pairs):
    run_stamp=f"{stamp}_{idx+1:02d}"
    label=f"unfair_{unfair_rate}_fair_{fair_rate}_{run_stamp}_proto_udp_fairlead_10s"
    ap_dir=raw/ap/exp/label
    fair_dir=raw/fair/exp/label
    unfair_dir=raw/unfair/exp/label
    for d in (ap_dir, fair_dir, unfair_dir):
        d.mkdir(parents=True, exist_ok=True)
    fair_rx=rate_num(fair_rate)*0.78
    unfair_rx=rate_num(unfair_rate)*0.58
    (ap_dir/f'{ap}_iperf_udp_server_p{fair_port}.log').write_text(iperf_lines(fair_rx, jitter=0.10+idx*0.01, loss=idx))
    (ap_dir/f'{ap}_iperf_udp_server_p{unfair_port}.log').write_text(iperf_lines(unfair_rx, jitter=0.15+idx*0.01, loss=idx+1))
    (fair_dir/f'{fair}_iperf_udp_client_fair_to_192.168.2.1_{fair_rate}_6s_p{fair_port}.log').write_text(client_log('192.168.2.1', fair_port, fair_rate, fair_rx))
    (unfair_dir/f'{unfair}_iperf_udp_client_unfair_to_192.168.2.1_{unfair_rate}_6s_p{unfair_port}.log').write_text(client_log('192.168.2.1', unfair_port, unfair_rate, unfair_rx))
print(f'Wrote dummy raw logs under {raw}')
PY
  organize_collected_results "$out" "$raw" "$stamp"
  rm -rf "$raw"
  local exp_dir="$out/$exp"
  if [[ ! -f "$exp_dir/experiment.conf" ]]; then
    export_config "$exp_dir/experiment.conf"
  fi
  parse_results "$exp_dir" "$exp_dir/summary.csv"
  plot_results "$exp_dir" "$exp_dir/summary.csv" "$PLOTS_DIR/$exp"
  echo "Dry-run results under: $exp_dir"
  echo "Dry-run plots under: $PLOTS_DIR/$exp"
  AP_NODE="$old_ap"; FAIR_NODE="$old_fair"; UNFAIR_NODE="$old_unfair"
  FAIR_PORT="$old_fair_port"; UNFAIR_PORT="$old_unfair_port"
}
status_nodes() {
  local nodes="${1:-}" n
  if [[ -z "$nodes" ]]; then nodes="$(all_nodes_csv)" || return 1; fi
  for n in $(split_csv "$nodes"); do
    echo "===== $n ====="
    node_bash "$n" "
set +e
hostname; date
lsmod | grep ath9k
for p in /sys/module/ath9k_hw/parameters/*; do [[ -f \"\$p\" ]] && echo \"\$(basename \"\$p\")=\$(cat \"\$p\")\"; done
ip addr show wlan0
iw dev wlan0 link
iw dev
dmesg | grep -i 'ath9k\|selfish\|txop\|backoff\|force\|reset' | tail -80
"
  done
}

# ---------- Menus ----------
setup_menu() {
  while true; do
    soft_clear
    echo "Setup"
    echo "====="
    echo "1) generate patch from source code"
    echo "2) set default nodes"
    echo "3) set default rates"
    echo "4) load image to nodes"
    echo "5) send patch + apply + build/install backports on nodes"
    echo "7) load settings from config"
    echo "8) export settings to config"
    echo "9) edit general settings"
    echo "b) back"
    read -r -p "Select: " c
    case "$c" in
      1) local p; p=$(prompt_default "Patch filename" "$PATCH_FILE"); run_action "generate patch" generate_patch "$p"; pause;;
      2) AP_NODE=$(prompt_default "AP1 node" "$AP_NODE"); AP2_NODE=$(prompt_default "AP2 node (optional, for two-AP topology)" "$AP2_NODE"); FAIR_NODE=$(prompt_default "Fair STA node" "$FAIR_NODE"); UNFAIR_NODE=$(prompt_default "Unfair STA node" "$UNFAIR_NODE"); AP_IP=$(prompt_default "AP1 IP" "$AP_IP"); AP2_IP=$(prompt_default "AP2 IP" "$AP2_IP"); FAIR_IP=$(prompt_default "Fair STA IP" "$FAIR_IP"); UNFAIR_IP=$(prompt_default "Unfair STA IP" "$UNFAIR_IP");;
      3) RATES=$(prompt_default "Rates comma-separated" "$RATES"); DURATION=$(prompt_default "Duration seconds" "$DURATION"); FIXED_RATE_DEFAULT=$(prompt_default "Default fixed rate" "$FIXED_RATE_DEFAULT"); DUAL_FAIR_LEAD_SECONDS=$(prompt_default "Dual tests: seconds to start fair STA before unfair STA" "$DUAL_FAIR_LEAD_SECONDS");;
      4) local nodes; nodes=$(prompt_default "Nodes comma-separated" "$(all_nodes_csv_or_empty)"); run_action "load image" load_image_to_nodes "$nodes"; pause;;
      5) local nodes p; nodes=$(prompt_default "Nodes comma-separated" "$(all_nodes_csv_or_empty)"); p=$(prompt_default "Patch file" "$PATCH_FILE"); run_action "send patch + build/install" deploy_patch_and_build_nodes "$nodes" "$p"; pause;;
      7) local f; f=$(prompt_default "Config file to load" "$SCRIPT_DIR/experiment.conf"); load_config "$f"; pause;;
      8) local f; f=$(prompt_default "Config file to write" "$SCRIPT_DIR/experiment.conf"); export_config "$f"; pause;;
      9) GATEWAY=$(prompt_default "Gateway" "$GATEWAY"); SLICE_NAME=$(prompt_default "Slice name" "$SLICE_NAME"); IMAGE=$(prompt_default "Image" "$IMAGE"); BACKPORTS_DIR=$(prompt_default "Backports dir on nodes" "$BACKPORTS_DIR"); NODE_LOG_DIR=$(prompt_default "Node log dir" "$NODE_LOG_DIR"); LOCAL_RESULTS_DIR=$(prompt_default "Local results dir" "$LOCAL_RESULTS_DIR"); PLOTS_DIR=$(prompt_default "Plots dir" "$PLOTS_DIR"); SSID=$(prompt_default "AP1 SSID" "$SSID"); AP2_SSID=$(prompt_default "AP2 SSID" "$AP2_SSID"); CHANNEL=$(prompt_default "Channel" "$CHANNEL"); SRC_REPO=$(prompt_default "Source repo" "$SRC_REPO"); BASE_REF=$(prompt_default "Base git ref" "$BASE_REF"); normalize_path_settings;;
      b|B) return 0;;
      *) echo "Unknown option"; sleep 1;;
    esac
  done
}

driver_options_menu() {
  while true; do
    soft_clear
    echo "Custom driver options"
    echo "====================="
    echo "Fair opts:   ${FAIR_DRIVER_OPTS:-<none>}"
    echo "Unfair opts: ${UNFAIR_DRIVER_OPTS:-<none>}"
    echo
    echo "1) select fair options (selfish/disable_backoff/chanel_idle/selfish_txop_us)"
    echo "2) select unfair options (selfish/disable_backoff/chanel_idle/selfish_txop_us)"
    echo "3) load drivers now with current options"
    echo "4) status/debug nodes"
    echo "b) back"
    read -r -p "Select: " c
    case "$c" in
      1) FAIR_DRIVER_OPTS=$(compose_driver_opts_prompt "fair STA" "$FAIR_DRIVER_OPTS");;
      2) UNFAIR_DRIVER_OPTS=$(compose_driver_opts_prompt "unfair STA" "$UNFAIR_DRIVER_OPTS");;
      3) run_action "load drivers" prepare_topology "$UNFAIR_DRIVER_OPTS" "$FAIR_DRIVER_OPTS" "n"; pause;;
      4) run_action "status" status_nodes "$(all_nodes_csv_or_empty)"; pause;;
      b|B) return 0;;
      *) echo "Unknown option"; sleep 1;;
    esac
  done
}

test_menu() {
  while true; do
    soft_clear
    echo "Test"
    echo "===="
    echo "1) fair node only"
    echo "2) unfair node only"
    echo "3) fair + unfair nodes"
    echo "4) AP1-fair + AP2-unfair nodes"
    echo "b) back"
    read -r -p "Select: " c
    case "$c" in
      1) run_action "fair node only" run_single_sta_experiment "fair"; pause;;
      2) run_action "unfair node only" run_single_sta_experiment "unfair"; pause;;
      3) run_action "fair + unfair nodes" run_dual_sta_experiment; pause;;
      4) run_action "AP1-fair + AP2-unfair nodes" run_two_ap_experiment; pause;;
      b|B) return 0;;
      *) echo "Unknown option"; sleep 1;;
    esac
  done
}

results_menu() {
  while true; do
    soft_clear
    echo "Results"
    echo "======="
    echo "1) fetch results from nodes"
    echo "2) parse results to CSV"
    echo "3) plot results"
    echo "4) parse + plot results"
    echo "5) dry-run with dummy nodes/logs"
    echo "b) back"
    read -r -p "Select: " c
    case "$c" in
      1) local out nodes; out=$(prompt_default "Local output dir" "$LOCAL_RESULTS_DIR/collected_$(ts)"); nodes=$(prompt_default "Nodes comma-separated" "$(all_nodes_csv_or_empty)"); run_action "fetch results" fetch_results "$out" "$nodes"; pause;;
      2) local dir csv; dir=$(prompt_default "Experiment log dir" "$LOCAL_RESULTS_DIR"); csv=$(prompt_default "CSV output" "$dir/summary.csv"); run_action "parse results" parse_results "$dir" "$csv"; pause;;
      3) local dir csv out; dir=$(prompt_default "Experiment log dir" "$LOCAL_RESULTS_DIR"); csv=$(prompt_default "CSV file" "$dir/summary.csv"); out=$(prompt_default "Plot output dir" "$PLOTS_DIR/$(basename "$dir")"); run_action "plot results" plot_results "$dir" "$csv" "$out"; pause;;
      4) local dir csv out; dir=$(prompt_default "Experiment log dir" "$LOCAL_RESULTS_DIR"); csv=$(prompt_default "CSV output" "$dir/summary.csv"); out=$(prompt_default "Plot output dir" "$PLOTS_DIR/$(basename "$dir")"); run_action "parse results" parse_results "$dir" "$csv"; run_action "plot results" plot_results "$dir" "$csv" "$out"; pause;;
      5) local out; out=$(prompt_default "Dry-run collected output dir" "$LOCAL_RESULTS_DIR/collected_$(ts)_dryrun"); run_action "dry-run dummy results" dry_run_results "$out"; pause;;
      b|B) return 0;;
      *) echo "Unknown option"; sleep 1;;
    esac
  done
}

main_menu() {
  while true; do
    soft_clear
    echo "ECE436 ath9k experiment suite"
    echo "=============================="
    settings_summary
    echo
    echo "1) Setup"
    echo "2) Custom driver options"
    echo "3) Test"
    echo "4) Results"
    echo "h) help"
    echo "q) quit"
    read -r -p "Select tab: " c
    case "$c" in
      1) setup_menu;;
      2) driver_options_menu;;
      3) test_menu;;
      4) results_menu;;
      h|H) usage; pause;;
      q|Q) echo "Bye."; return 0;;
      *) echo "Unknown option"; sleep 1;;
    esac
  done
}

usage() {
  cat <<EOF
Usage:
  ./run.sh                         # interactive menu
  ./run.sh menu
  ./run.sh generate-patch [file]
  ./run.sh load-config file
  ./run.sh export-config file
  ./run.sh deploy-driver [nodes_csv] [patch_file]
  ./run.sh fetch-results [out_dir] [nodes_csv]
  ./run.sh parse-results experiment_dir [csv]
  ./run.sh plot-results experiment_dir [csv] [plot_dir]
  ./run.sh dry-run [out_dir]
  ./run.sh status [nodes_csv]

The interactive menu has tabs:
  1) Setup
  2) Custom driver options
  3) Test
  4) Results
EOF
}

cmd="${1:-menu}"; [[ $# -gt 0 ]] && shift || true
case "$cmd" in
  menu|interactive) load_default_config_if_present; main_menu;;
  generate-patch) generate_patch "${1:-$PATCH_FILE}";;
  load-config) load_config "${1:?config file required}";;
  export-config) export_config "${1:?config file required}";;
  deploy-driver) deploy_patch_and_build_nodes "${1:-}" "${2:-$PATCH_FILE}";;
  fetch-results) fetch_results "${1:-$LOCAL_RESULTS_DIR/collected_$(ts)}" "${2:-}";;
  parse-results) parse_results "${1:?experiment dir required}" "${2:-${1:?}/summary.csv}";;
  plot-results) plot_results "${1:?experiment dir required}" "${2:-${1:?}/summary.csv}" "${3:-$PLOTS_DIR/$(basename "${1:?}")}";;
  dry-run|dryrun) dry_run_results "${1:-$LOCAL_RESULTS_DIR/collected_$(ts)_dryrun}";;
  status) status_nodes "${1:-}";;
  -h|--help|help) usage;;
  *) echo "Unknown command: $cmd" >&2; usage; exit 1;;
esac
