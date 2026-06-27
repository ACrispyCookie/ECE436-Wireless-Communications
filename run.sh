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
# This script intentionally keeps all experiment outputs separated by labels that
# include test type, selected rates, driver option tags, and timestamp.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Persistent/default settings ----------
GATEWAY="${GATEWAY:-dtsiantos@nitlab3.inf.uth.gr}"
SLICE_NAME="${SLICE_NAME:-}"
IMAGE="${IMAGE:-baseline_wireless_communications.ndz}"
BACKPORTS_DIR="${BACKPORTS_DIR:-/root/backports-5.4.56-1}"
NODE_LOG_DIR="${NODE_LOG_DIR:-/root/ece436_exp_logs}"
LOCAL_RESULTS_DIR="${LOCAL_RESULTS_DIR:-$SCRIPT_DIR/results}"
PATCH_FILE="${PATCH_FILE:-$SCRIPT_DIR/ath9k_experiment.patch}"
SRC_REPO="${SRC_REPO:-$SCRIPT_DIR}"
BASE_REF="${BASE_REF:-origin/baseline}"

AP_NODE="${AP_NODE:-node069}"
FAIR_NODE="${FAIR_NODE:-node084}"
UNFAIR_NODE="${UNFAIR_NODE:-node088}"
AP_IP="${AP_IP:-192.168.2.1}"
FAIR_IP="${FAIR_IP:-192.168.2.2}"
UNFAIR_IP="${UNFAIR_IP:-192.168.2.3}"
SSID="${SSID:-tsiantos}"
CHANNEL="${CHANNEL:-7}"
RATES="${RATES:-5M,25M,50M,150M}"
DURATION="${DURATION:-60}"
FIXED_RATE_DEFAULT="${FIXED_RATE_DEFAULT:-150M}"

# Driver module options passed to ath9k_hw. Keep every known custom option
# explicit in labels/configs so result directories document the exact mode.
# NOTE: "chanel_idle" intentionally preserves the driver's exported typo.
FAIR_DRIVER_OPTS="${FAIR_DRIVER_OPTS:-selfish_mode=0 disable_backoff=0 chanel_idle=0}"
UNFAIR_DRIVER_OPTS="${UNFAIR_DRIVER_OPTS:-selfish_mode=1 disable_backoff=0 chanel_idle=0}"

# IPERF defaults. iperf2 is assumed because NITLab images used iperf2 in previous tests.
FAIR_PORT="${FAIR_PORT:-5004}"
UNFAIR_PORT="${UNFAIR_PORT:-5003}"
TCP_PORT_BASE="${TCP_PORT_BASE:-5010}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no)

# ---------- Small helpers ----------
all_nodes_csv() { printf '%s,%s,%s' "$AP_NODE" "$FAIR_NODE" "$UNFAIR_NODE"; }
split_csv() { tr ',' ' ' <<<"$1"; }
ts() { date +%Y%m%d_%H%M%S; }
safe() { sed 's/[^A-Za-z0-9_.-]/_/g' <<<"$1"; }
join_opts_tag() { local x="${1:-none}"; x="${x// /_}"; safe "$x"; }
rate_tag() { safe "$1"; }

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

bool_default_letter() {
  local value="${1:-0}"
  if [[ "$value" == "1" || "$value" =~ ^[Yy] ]]; then printf 'y'; else printf 'n'; fi
}

compose_driver_opts_prompt() {
  local label="$1" current="$2" selfish disable idle extra opts
  echo "Current $label options: ${current:-<none>}" >&2
  if prompt_yes_no "$label: selfish_mode" "$(bool_default_letter "$(get_opt_value "$current" selfish_mode 0)")"; then selfish=1; else selfish=0; fi
  if prompt_yes_no "$label: disable_backoff" "$(bool_default_letter "$(get_opt_value "$current" disable_backoff 0)")"; then disable=1; else disable=0; fi
  if prompt_yes_no "$label: chanel_idle (driver typo, AR_DIAG_FORCE_CH_IDLE_HIGH)" "$(bool_default_letter "$(get_opt_value "$current" chanel_idle 0)")"; then idle=1; else idle=0; fi
  extra=$(prompt_default "$label: extra ath9k_hw options, if any" "")
  opts="selfish_mode=$selfish disable_backoff=$disable chanel_idle=$idle"
  [[ -n "$extra" ]] && opts="$opts $extra"
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
Image:             $IMAGE
Backports dir:     $BACKPORTS_DIR
Node log dir:      $NODE_LOG_DIR
Local results dir: $LOCAL_RESULTS_DIR
Patch file:        $PATCH_FILE
Source repo:       $SRC_REPO
Base ref:          $BASE_REF
AP:                $AP_NODE ($AP_IP)
Fair STA:          $FAIR_NODE ($FAIR_IP)
Unfair STA:        $UNFAIR_NODE ($UNFAIR_IP)
SSID/channel:      $SSID / $CHANNEL
Default rates:     $RATES
Duration:          ${DURATION}s
Fair driver opts:  ${FAIR_DRIVER_OPTS:-<none>}
Unfair drv opts:   ${UNFAIR_DRIVER_OPTS:-<none>}
EOF
}

gw() { ssh "${SSH_OPTS[@]}" "$GATEWAY" "$@"; }
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
  GATEWAY SLICE_NAME IMAGE BACKPORTS_DIR NODE_LOG_DIR LOCAL_RESULTS_DIR PATCH_FILE SRC_REPO BASE_REF
  AP_NODE FAIR_NODE UNFAIR_NODE AP_IP FAIR_IP UNFAIR_IP SSID CHANNEL RATES DURATION FIXED_RATE_DEFAULT
  FAIR_DRIVER_OPTS UNFAIR_DRIVER_OPTS FAIR_PORT UNFAIR_PORT TCP_PORT_BASE
)

export_config() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  {
    echo "# ECE436 ath9k experiment-suite config"
    echo "# Generated: $(date -Is)"
    local k
    for k in "${config_keys[@]}"; do
      printf '%s=%q\n' "$k" "${!k}"
    done
  } > "$file"
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
  echo "Loaded config: $file"
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
  local nodes="${1:-$(all_nodes_csv)}"
  echo "[omf] image=$IMAGE nodes=$nodes"
  if [[ -n "$SLICE_NAME" ]]; then echo "[omf] slice=$SLICE_NAME"; fi
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
  [[ -s "$patch_file" ]] || { echo "Patch file not found or empty: $patch_file" >&2; return 1; }
  echo "[patch] copy $patch_file -> $node:$remote_patch"
  scp "${SSH_OPTS[@]}" "$patch_file" "$GATEWAY:/tmp/$(basename "$patch_file")"
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
  if [[ \"\$install_rc\" -ne 0 ]]; then
    if modinfo ath9k_hw 2>/dev/null | grep -q 'disable_backoff'; then
      echo '[build] WARNING: make install returned non-zero, but patched ath9k_hw params are visible; continuing'
    else
      echo '[build] ERROR: make install returned non-zero and patched ath9k_hw params are not visible' >&2
      exit \"\$install_rc\"
    fi
  fi
} 2>&1 | tee \"\$log\"
"
}

deploy_patch_and_build_nodes() {
  local nodes="${1:-$(all_nodes_csv)}" patch_file="${2:-$PATCH_FILE}" n
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
killall hostapd 2>/dev/null || true
ip link set wlan0 down 2>/dev/null || true
modprobe -r ath9k ath9k_common ath9k_hw ath mac80211 cfg80211 2>/dev/null || true
modprobe ath9k_hw $opts
modprobe ath9k
{
  date
  echo 'modprobe ath9k_hw $opts; modprobe ath9k'
  lsmod | grep ath9k || true
  for p in /sys/module/ath9k_hw/parameters/*; do [[ -f \"\$p\" ]] && echo \"\$(basename \"\$p\")=\$(cat \"\$p\")\"; done
  echo '[dmesg] new ath9k-related lines from this load only:'
  dmesg 2>/dev/null | tail -n +\$((dmesg_start + 1)) | grep -i 'ath9k\|selfish\|backoff\|force' || true
} | tee '$NODE_LOG_DIR/setup/${node}_load_driver_$(join_opts_tag "$opts").log'
"
}

start_ap() {
  local mode="${1:-n}" # n or g
  local ieee80211n=1 hw_mode=g
  if [[ "$mode" == "g" ]]; then ieee80211n=0; hw_mode=g; fi
  node_bash "$AP_NODE" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/setup'
if ! command -v hostapd >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt install -y hostapd
fi
cat > /root/ece436_ap.conf <<EOF_AP
interface=wlan0
driver=nl80211
ssid=$SSID
hw_mode=$hw_mode
channel=$CHANNEL
ieee80211n=$ieee80211n
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
EOF_AP
ip link set wlan0 down 2>/dev/null || true
ifconfig wlan0 '$AP_IP' up
killall hostapd 2>/dev/null || true
nohup hostapd -dd /root/ece436_ap.conf > '$NODE_LOG_DIR/setup/${AP_NODE}_hostapd_${mode}.log' 2>&1 & echo \$! > '$NODE_LOG_DIR/setup/${AP_NODE}_hostapd.pid'
sleep 2
cat '$NODE_LOG_DIR/setup/${AP_NODE}_hostapd.pid'
tail -40 '$NODE_LOG_DIR/setup/${AP_NODE}_hostapd_${mode}.log' || true
"
}

connect_sta() {
  local node="$1" ip="$2"
  node_bash "$node" "
set -euo pipefail
mkdir -p '$NODE_LOG_DIR/setup'
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
} | tee '$NODE_LOG_DIR/setup/${node}_connect.log'
"
}

prepare_topology() {
  local unfair_opts="$1" fair_opts="$2" mode="${3:-n}"
  load_driver_on_node "$AP_NODE" "selfish_mode=0 disable_backoff=0 chanel_idle=0" || return 1
  load_driver_on_node "$FAIR_NODE" "$fair_opts" || return 1
  load_driver_on_node "$UNFAIR_NODE" "$unfair_opts" || return 1
  start_ap "$mode" || return 1
  connect_sta "$FAIR_NODE" "$FAIR_IP" || return 1
  connect_sta "$UNFAIR_NODE" "$UNFAIR_IP" || return 1
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
  local proto="$1" fair_rate="$2" unfair_rate="$3" duration="$4" label="$5"
  iperf_server "$AP_NODE" "$proto" "$FAIR_PORT" "$label" || return 1
  iperf_server "$AP_NODE" "$proto" "$UNFAIR_PORT" "$label" || return 1
  sleep 2
  iperf_client "$FAIR_NODE" "$proto" "$AP_IP" "$fair_rate" "$duration" "$FAIR_PORT" "$label" "fair" &
  local fair_pid=$!
  iperf_client "$UNFAIR_NODE" "$proto" "$AP_IP" "$unfair_rate" "$duration" "$UNFAIR_PORT" "$label" "unfair" &
  local unfair_pid=$!
  local rc1=0 rc2=0
  wait "$fair_pid" || rc1=$?
  wait "$unfair_pid" || rc2=$?
  [[ "$rc1" -eq 0 && "$rc2" -eq 0 ]]
}

run_single_sta_sweep() {
  local which="$1" proto="$2" rates="$3" duration="$4" prefix="$5"
  local node ip port tag rate label
  if [[ "$which" == "fair" ]]; then node="$FAIR_NODE"; port="$FAIR_PORT"; tag="fair"; else node="$UNFAIR_NODE"; port="$UNFAIR_PORT"; tag="unfair"; fi
  for rate in $(split_csv "$rates"); do
    label="${prefix}_${tag}_only_rate_$(rate_tag "$rate")"
    iperf_server "$AP_NODE" "$proto" "$port" "$label" || return 1
    sleep 2
    iperf_client "$node" "$proto" "$AP_IP" "$rate" "$duration" "$port" "$label" "$tag" || return 1
  done
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

run_dual_test_with_plan() {
  local test_name="$1" proto="$2" fair_opts="$3" unfair_opts="$4" wifi_mode="$5"
  local duration prefix plan mode fixed_node fixed_rate sweep_rates rate fair_rate unfair_rate label
  duration=$(prompt_default "Duration seconds per run" "$DURATION")
  prefix=$(prompt_default "Log prefix" "${test_name}_$(ts)")
  IFS='|' read -r mode fixed_node fixed_rate sweep_rates <<<"$(ask_fixed_rate_plan)"
  if prompt_yes_no "Prepare topology/load drivers before test?" "y"; then
    prepare_topology "$unfair_opts" "$fair_opts" "$wifi_mode" || return 1
  fi
  local fair_tag unfair_tag
  fair_tag=$(join_opts_tag "$fair_opts")
  unfair_tag=$(join_opts_tag "$unfair_opts")
  case "$mode" in
    none)
      for rate in $(split_csv "$sweep_rates"); do
        label="${prefix}_proto_${proto}_rate_$(rate_tag "$rate")_fair_${fair_tag}_unfair_${unfair_tag}"
        run_two_sta_once "$proto" "$rate" "$rate" "$duration" "$label" || return 1
      done
      ;;
    unfair)
      for rate in $(split_csv "$sweep_rates"); do
        label="${prefix}_proto_${proto}_fair_sweep_$(rate_tag "$rate")_unfair_fixed_$(rate_tag "$fixed_rate")_fair_${fair_tag}_unfair_${unfair_tag}"
        run_two_sta_once "$proto" "$rate" "$fixed_rate" "$duration" "$label" || return 1
      done
      ;;
    fair)
      for rate in $(split_csv "$sweep_rates"); do
        label="${prefix}_proto_${proto}_fair_fixed_$(rate_tag "$fixed_rate")_unfair_sweep_$(rate_tag "$rate")_fair_${fair_tag}_unfair_${unfair_tag}"
        run_two_sta_once "$proto" "$fixed_rate" "$rate" "$duration" "$label" || return 1
      done
      ;;
    both)
      IFS=',' read -r fair_rate unfair_rate <<<"$fixed_rate"
      label="${prefix}_proto_${proto}_fair_fixed_$(rate_tag "$fair_rate")_unfair_fixed_$(rate_tag "$unfair_rate")_fair_${fair_tag}_unfair_${unfair_tag}"
      run_two_sta_once "$proto" "$fair_rate" "$unfair_rate" "$duration" "$label" || return 1
      ;;
  esac
}

# ---------- Results ----------
fetch_results() {
  local out="${1:-$LOCAL_RESULTS_DIR/collected_$(ts)}" nodes="${2:-$(all_nodes_csv)}"
  mkdir -p "$out"
  local stamp n
  stamp="$(ts)"
  for n in $(split_csv "$nodes"); do
    echo "[fetch] $n -> $out/$n"
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
    scp "${SSH_OPTS[@]}" "$GATEWAY:/tmp/${n}_ece436_logs_${stamp}.tar.gz" "$out/"
    mkdir -p "$out/$n"
    tar xzf "$out/${n}_ece436_logs_${stamp}.tar.gz" -C "$out/$n"
  done
  echo "Collected logs under: $out"
}

parse_results() {
  local indir="$1" out="${2:-$indir/iperf_summary.csv}"
  [[ -d "$indir" ]] || { echo "Input directory not found: $indir" >&2; return 1; }
  python3 - "$indir" "$out" <<'PY'
import csv, re, sys
from pathlib import Path
indir = Path(sys.argv[1])
out = Path(sys.argv[2])
bw_re = re.compile(r'\[\s*\d+\]\s+(?P<interval>\d+(?:\.\d+)?\s*-\s*\d+(?:\.\d+)?)\s+sec\s+(?P<transfer>[\d.]+)\s+(?P<transfer_unit>[KMG]?Bytes)\s+(?P<bw>[\d.]+)\s+(?P<bw_unit>[KMG]?bits/sec)(?:\s+(?P<jitter>[\d.]+)\s+ms\s+(?P<lost>\d+)\s*/\s*(?P<total>\d+)\s*\((?P<loss_pct>[\d.]+)%\))?')
cmd_re = re.compile(r'iperf\s+-c\s+(?P<server_ip>\S+).*?(?:-u\s+)?-p\s+(?P<port>\d+)(?:.*?-b\s+(?P<rate>\S+))?.*?-t\s+(?P<duration>\S+)')
rows=[]
for f in sorted(indir.rglob('*iperf*log')):
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
    label=''
    if len(parts) >= 3:
        # node/<label>/file.log or node/setup/file.log
        label=parts[-2]
    name=f.name
    role='server' if '_server_' in name else 'client' if '_client_' in name else 'unknown'
    proto='tcp' if '_tcp_' in name else 'udp' if '_udp_' in name else 'unknown'
    port=''; offered_rate=''; duration=''; server_ip=''
    pm=re.search(r'_p(\d+)\.log$', name)
    if pm: port=pm.group(1)
    for l2 in lines:
        cm=cmd_re.search(l2)
        if cm:
            server_ip=cm.group('server_ip'); port=cm.group('port') or port; offered_rate=cm.group('rate') or ''; duration=cm.group('duration') or ''
            break
    # Keep all interval rows plus mark final row. This supports time plots.
    for idx,(ln,m) in enumerate(matches):
        rows.append({
            'label': label, 'node': node, 'role': role, 'proto': proto, 'port': port,
            'offered_rate': offered_rate, 'duration_s': duration, 'server_ip': server_ip,
            'interval_s': m.group('interval').replace(' ', ''), 'is_final': '1' if idx == len(matches)-1 else '0',
            'transfer': m.group('transfer'), 'transfer_unit': m.group('transfer_unit'),
            'bandwidth': m.group('bw'), 'bandwidth_unit': m.group('bw_unit'),
            'jitter_ms': m.group('jitter') or '', 'lost': m.group('lost') or '', 'total': m.group('total') or '', 'loss_pct': m.group('loss_pct') or '',
            'source_file': str(rel), 'summary_line': ln,
        })
out.parent.mkdir(parents=True, exist_ok=True)
fields=['label','node','role','proto','port','offered_rate','duration_s','server_ip','interval_s','is_final','transfer','transfer_unit','bandwidth','bandwidth_unit','jitter_ms','lost','total','loss_pct','source_file','summary_line']
with out.open('w', newline='') as fh:
    w=csv.DictWriter(fh, fieldnames=fields); w.writeheader(); w.writerows(rows)
print(f'Wrote {len(rows)} rows to {out}')
print('Final receiver/server rows:')
for r in rows:
    if r['role']=='server' and r['is_final']=='1':
        loss = f" loss={r['lost']}/{r['total']} ({r['loss_pct']}%)" if r['lost'] else ''
        print(f"{r['label']} {r['node']} {r['proto']} port={r['port']} bw={r['bandwidth']} {r['bandwidth_unit']}{loss}")
PY
}

plot_results() {
  local indir="$1" csv="${2:-$indir/iperf_summary.csv}" outdir="${3:-$indir/plots}"
  [[ -f "$csv" ]] || parse_results "$indir" "$csv"
  python3 - "$csv" "$outdir" <<'PY'
import csv, re, sys
from collections import defaultdict
from pathlib import Path
csv_path=Path(sys.argv[1]); outdir=Path(sys.argv[2]); outdir.mkdir(parents=True, exist_ok=True)
try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
except Exception:
    plt = None

def bw_mbps(v,u):
    x=float(v)
    if u.startswith('K'): return x/1000.0
    if u.startswith('G'): return x*1000.0
    return x

def start_s(interval):
    m=re.match(r'([0-9.]+)-', interval or '')
    return float(m.group(1)) if m else 0.0
rows=list(csv.DictReader(csv_path.open()))
series=defaultdict(list)
for r in rows:
    if r.get('role')!='server' or r.get('is_final')=='1':
        continue
    try: y=bw_mbps(r['bandwidth'], r['bandwidth_unit'])
    except Exception: continue
    key=(r['label'], f"server_port_{r['port']}")
    series[key].append((start_s(r['interval_s']), y))
labels=sorted(set(k[0] for k in series))

def write_svg(path, label, label_series):
    width, height = 1000, 520
    ml, mr, mt, mb = 70, 30, 55, 70
    colors = ['#1f77b4', '#d62728', '#2ca02c', '#9467bd', '#ff7f0e', '#17becf']
    allpts=[p for _,pts in label_series for p in pts]
    if not allpts:
        return
    xmax=max([p[0] for p in allpts] + [1.0])
    ymax=max([p[1] for p in allpts] + [1.0])
    def sx(x): return ml + (x / xmax) * (width - ml - mr)
    def sy(y): return height - mb - (y / ymax) * (height - mt - mb)
    def esc(s): return str(s).replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
    parts=[]
    parts.append(f"<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{height}' viewBox='0 0 {width} {height}'>")
    parts.append("<rect width='100%' height='100%' fill='white'/>")
    parts.append(f"<text x='{width/2}' y='28' text-anchor='middle' font-family='sans-serif' font-size='18'>{esc(label)}</text>")
    parts.append(f"<line x1='{ml}' y1='{height-mb}' x2='{width-mr}' y2='{height-mb}' stroke='black'/>")
    parts.append(f"<line x1='{ml}' y1='{mt}' x2='{ml}' y2='{height-mb}' stroke='black'/>")
    for i in range(6):
        x=xmax*i/5; px=sx(x)
        parts.append(f"<line x1='{px:.1f}' y1='{height-mb}' x2='{px:.1f}' y2='{height-mb+5}' stroke='black'/>")
        parts.append(f"<text x='{px:.1f}' y='{height-mb+22}' text-anchor='middle' font-family='sans-serif' font-size='11'>{x:.0f}</text>")
        y=ymax*i/5; py=sy(y)
        parts.append(f"<line x1='{ml-5}' y1='{py:.1f}' x2='{ml}' y2='{py:.1f}' stroke='black'/>")
        parts.append(f"<text x='{ml-8}' y='{py+4:.1f}' text-anchor='end' font-family='sans-serif' font-size='11'>{y:.1f}</text>")
        if i>0:
            parts.append(f"<line x1='{ml}' y1='{py:.1f}' x2='{width-mr}' y2='{py:.1f}' stroke='#ddd'/>")
    parts.append(f"<text x='{width/2}' y='{height-25}' text-anchor='middle' font-family='sans-serif' font-size='13'>time (s)</text>")
    parts.append(f"<text x='18' y='{height/2}' transform='rotate(-90 18 {height/2})' text-anchor='middle' font-family='sans-serif' font-size='13'>receiver bandwidth (Mbit/s)</text>")
    for idx,(name,pts) in enumerate(label_series):
        pts=sorted(pts)
        color=colors[idx % len(colors)]
        d=' '.join(f"{sx(x):.1f},{sy(y):.1f}" for x,y in pts)
        parts.append(f"<polyline fill='none' stroke='{color}' stroke-width='2' points='{d}'/>")
        for x,y in pts:
            parts.append(f"<circle cx='{sx(x):.1f}' cy='{sy(y):.1f}' r='3' fill='{color}'/>")
        ly=55 + idx*20
        parts.append(f"<rect x='{width-220}' y='{ly-10}' width='14' height='3' fill='{color}'/>")
        parts.append(f"<text x='{width-200}' y='{ly-5}' font-family='sans-serif' font-size='12'>{esc(name)}</text>")
    parts.append('</svg>')
    path.write_text('\n'.join(parts))

made=0
for label in labels:
    label_series=[]
    for (lbl,name),pts in sorted(series.items()):
        if lbl==label and pts:
            label_series.append((name, sorted(pts)))
    if not label_series:
        continue
    safe=re.sub(r'[^A-Za-z0-9_.-]+','_',label)[:180]
    if plt is not None:
        plt.figure(figsize=(10,5))
        for name,pts in label_series:
            xs=[p[0] for p in pts]; ys=[p[1] for p in pts]
            plt.plot(xs, ys, marker='o', linewidth=1.4, label=name)
        plt.title(label)
        plt.xlabel('time (s)')
        plt.ylabel('receiver bandwidth (Mbit/s)')
        plt.grid(True, alpha=0.3)
        plt.legend()
        plt.tight_layout()
        path=outdir/f'{safe}.png'
        plt.savefig(path, dpi=140)
        plt.close()
    else:
        path=outdir/f'{safe}.svg'
        write_svg(path, label, label_series)
    print(path)
    made+=1
print(f'Wrote {made} plots to {outdir}')
PY
}

status_nodes() {
  local nodes="${1:-$(all_nodes_csv)}" n
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
dmesg | grep -i 'ath9k\|selfish\|backoff\|force\|reset' | tail -80
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
    echo "5) load image to one node"
    echo "6) send patch + apply + build/install backports on nodes"
    echo "7) load settings from config"
    echo "8) export settings to config"
    echo "9) edit general settings"
    echo "b) back"
    read -r -p "Select: " c
    case "$c" in
      1) local p; p=$(prompt_default "Patch filename" "$PATCH_FILE"); run_action "generate patch" generate_patch "$p"; pause;;
      2) AP_NODE=$(prompt_default "AP node" "$AP_NODE"); FAIR_NODE=$(prompt_default "Fair STA node" "$FAIR_NODE"); UNFAIR_NODE=$(prompt_default "Unfair STA node" "$UNFAIR_NODE"); AP_IP=$(prompt_default "AP IP" "$AP_IP"); FAIR_IP=$(prompt_default "Fair STA IP" "$FAIR_IP"); UNFAIR_IP=$(prompt_default "Unfair STA IP" "$UNFAIR_IP");;
      3) RATES=$(prompt_default "Rates comma-separated" "$RATES"); DURATION=$(prompt_default "Duration seconds" "$DURATION"); FIXED_RATE_DEFAULT=$(prompt_default "Default fixed rate" "$FIXED_RATE_DEFAULT");;
      4) local nodes; nodes=$(prompt_default "Nodes comma-separated" "$(all_nodes_csv)"); run_action "load image" load_image_to_nodes "$nodes"; pause;;
      5) local node; node=$(prompt_default "Single node to image" "$UNFAIR_NODE"); run_action "load image on one node: $node" load_image_to_nodes "$node"; pause;;
      6) local nodes p; nodes=$(prompt_default "Nodes comma-separated" "$(all_nodes_csv)"); p=$(prompt_default "Patch file" "$PATCH_FILE"); run_action "send patch + build/install" deploy_patch_and_build_nodes "$nodes" "$p"; pause;;
      7) local f; f=$(prompt_default "Config file to load" "$SCRIPT_DIR/experiment.conf"); load_config "$f"; pause;;
      8) local f; f=$(prompt_default "Config file to write" "$SCRIPT_DIR/experiment.conf"); export_config "$f"; pause;;
      9) GATEWAY=$(prompt_default "Gateway" "$GATEWAY"); SLICE_NAME=$(prompt_default "Slice name" "$SLICE_NAME"); IMAGE=$(prompt_default "Image" "$IMAGE"); BACKPORTS_DIR=$(prompt_default "Backports dir on nodes" "$BACKPORTS_DIR"); NODE_LOG_DIR=$(prompt_default "Node log dir" "$NODE_LOG_DIR"); LOCAL_RESULTS_DIR=$(prompt_default "Local results dir" "$LOCAL_RESULTS_DIR"); SSID=$(prompt_default "SSID" "$SSID"); CHANNEL=$(prompt_default "Channel" "$CHANNEL"); SRC_REPO=$(prompt_default "Source repo" "$SRC_REPO"); BASE_REF=$(prompt_default "Base git ref" "$BASE_REF");;
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
    echo "1) set fair STA ath9k_hw options (raw string)"
    echo "2) set unfair STA ath9k_hw options (raw string)"
    echo "3) baseline preset for both STAs"
    echo "4) selfish preset: fair=0, unfair=1"
    echo "5) prompt/toggle fair options (selfish/disable_backoff/chanel_idle)"
    echo "6) prompt/toggle unfair options (selfish/disable_backoff/chanel_idle)"
    echo "7) unfair disable_backoff preset"
    echo "8) unfair chanel_idle preset"
    echo "9) unfair disable_backoff + chanel_idle preset"
    echo "10) load drivers now with current options"
    echo "11) status/debug nodes"
    echo "b) back"
    read -r -p "Select: " c
    case "$c" in
      1) FAIR_DRIVER_OPTS=$(prompt_default "Fair ath9k_hw module options" "$FAIR_DRIVER_OPTS");;
      2) UNFAIR_DRIVER_OPTS=$(prompt_default "Unfair ath9k_hw module options" "$UNFAIR_DRIVER_OPTS");;
      3) FAIR_DRIVER_OPTS="selfish_mode=0 disable_backoff=0 chanel_idle=0"; UNFAIR_DRIVER_OPTS="selfish_mode=0 disable_backoff=0 chanel_idle=0"; echo "Preset applied."; sleep 1;;
      4) FAIR_DRIVER_OPTS="selfish_mode=0 disable_backoff=0 chanel_idle=0"; UNFAIR_DRIVER_OPTS="selfish_mode=1 disable_backoff=0 chanel_idle=0"; echo "Preset applied."; sleep 1;;
      5) FAIR_DRIVER_OPTS=$(compose_driver_opts_prompt "fair STA" "$FAIR_DRIVER_OPTS");;
      6) UNFAIR_DRIVER_OPTS=$(compose_driver_opts_prompt "unfair STA" "$UNFAIR_DRIVER_OPTS");;
      7) FAIR_DRIVER_OPTS="selfish_mode=0 disable_backoff=0 chanel_idle=0"; UNFAIR_DRIVER_OPTS="selfish_mode=1 disable_backoff=1 chanel_idle=0"; echo "Preset applied."; sleep 1;;
      8) FAIR_DRIVER_OPTS="selfish_mode=0 disable_backoff=0 chanel_idle=0"; UNFAIR_DRIVER_OPTS="selfish_mode=1 disable_backoff=0 chanel_idle=1"; echo "Preset applied."; sleep 1;;
      9) FAIR_DRIVER_OPTS="selfish_mode=0 disable_backoff=0 chanel_idle=0"; UNFAIR_DRIVER_OPTS="selfish_mode=1 disable_backoff=1 chanel_idle=1"; echo "Preset applied."; sleep 1;;
      10) run_action "load drivers" prepare_topology "$UNFAIR_DRIVER_OPTS" "$FAIR_DRIVER_OPTS" "n"; pause;;
      11) run_action "status" status_nodes "$(all_nodes_csv)"; pause;;
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
    echo "1) unfair node only"
    echo "2) fair node only"
    echo "3) UDP: AP + fair/unfair STAs simultaneous"
    echo "4) only fair nodes"
    echo "5) TCP: AP + fair/unfair STAs"
    echo "6) wifi with less speed: 802.11g"
    echo "b) back"
    read -r -p "Select: " c
    case "$c" in
      1)
        local rates duration prefix
        rates=$(prompt_default "Rates comma-separated" "$RATES")
        duration=$(prompt_default "Duration seconds per rate" "$DURATION")
        prefix=$(prompt_default "Log prefix" "unfair_only_$(ts)_unfair_$(join_opts_tag "$UNFAIR_DRIVER_OPTS")")
        if prompt_yes_no "Prepare AP + unfair STA before test?" "y"; then
          load_driver_on_node "$AP_NODE" "selfish_mode=0 disable_backoff=0 chanel_idle=0" && load_driver_on_node "$UNFAIR_NODE" "$UNFAIR_DRIVER_OPTS" && start_ap "n" && connect_sta "$UNFAIR_NODE" "$UNFAIR_IP"
        fi
        run_action "unfair node only" run_single_sta_sweep "unfair" "udp" "$rates" "$duration" "$prefix"; pause;;
      2)
        local rates duration prefix
        rates=$(prompt_default "Rates comma-separated" "$RATES")
        duration=$(prompt_default "Duration seconds per rate" "$DURATION")
        prefix=$(prompt_default "Log prefix" "fair_only_$(ts)_fair_$(join_opts_tag "$FAIR_DRIVER_OPTS")")
        if prompt_yes_no "Prepare AP + fair STA before test?" "y"; then
          load_driver_on_node "$AP_NODE" "selfish_mode=0 disable_backoff=0 chanel_idle=0" && load_driver_on_node "$FAIR_NODE" "$FAIR_DRIVER_OPTS" && start_ap "n" && connect_sta "$FAIR_NODE" "$FAIR_IP"
        fi
        run_action "fair node only" run_single_sta_sweep "fair" "udp" "$rates" "$duration" "$prefix"; pause;;
      3)
        run_action "UDP fair/unfair simultaneous" run_dual_test_with_plan "fair_unfair_udp" "udp" "$FAIR_DRIVER_OPTS" "$UNFAIR_DRIVER_OPTS" "n"; pause;;
      4)
        run_action "only fair nodes" run_dual_test_with_plan "only_fair_nodes" "udp" "selfish_mode=0 disable_backoff=0 chanel_idle=0" "selfish_mode=0 disable_backoff=0 chanel_idle=0" "n"; pause;;
      5)
        run_action "TCP fair/unfair" run_dual_test_with_plan "tcp" "tcp" "$FAIR_DRIVER_OPTS" "$UNFAIR_DRIVER_OPTS" "n"; pause;;
      6)
        run_action "802.11g lower-speed wifi" run_dual_test_with_plan "wifi_11g" "udp" "$FAIR_DRIVER_OPTS" "$UNFAIR_DRIVER_OPTS" "g"; pause;;
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
    echo "b) back"
    read -r -p "Select: " c
    case "$c" in
      1) local out nodes; out=$(prompt_default "Local output dir" "$LOCAL_RESULTS_DIR/collected_$(ts)"); nodes=$(prompt_default "Nodes comma-separated" "$(all_nodes_csv)"); run_action "fetch results" fetch_results "$out" "$nodes"; pause;;
      2) local dir csv; dir=$(prompt_default "Collected log dir" "$LOCAL_RESULTS_DIR"); csv=$(prompt_default "CSV output" "$dir/iperf_summary.csv"); run_action "parse results" parse_results "$dir" "$csv"; pause;;
      3) local dir csv out; dir=$(prompt_default "Collected log dir" "$LOCAL_RESULTS_DIR"); csv=$(prompt_default "CSV file" "$dir/iperf_summary.csv"); out=$(prompt_default "Plot output dir" "$dir/plots"); run_action "plot results" plot_results "$dir" "$csv" "$out"; pause;;
      4) local dir csv out; dir=$(prompt_default "Collected log dir" "$LOCAL_RESULTS_DIR"); csv=$(prompt_default "CSV output" "$dir/iperf_summary.csv"); out=$(prompt_default "Plot output dir" "$dir/plots"); run_action "parse results" parse_results "$dir" "$csv"; run_action "plot results" plot_results "$dir" "$csv" "$out"; pause;;
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
  ./run.sh parse-results log_dir [csv]
  ./run.sh plot-results log_dir [csv] [plot_dir]
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
  menu|interactive) main_menu;;
  generate-patch) generate_patch "${1:-$PATCH_FILE}";;
  load-config) load_config "${1:?config file required}";;
  export-config) export_config "${1:?config file required}";;
  deploy-driver) deploy_patch_and_build_nodes "${1:-$(all_nodes_csv)}" "${2:-$PATCH_FILE}";;
  fetch-results) fetch_results "${1:-$LOCAL_RESULTS_DIR/collected_$(ts)}" "${2:-$(all_nodes_csv)}";;
  parse-results) parse_results "${1:?log dir required}" "${2:-${1:?}/iperf_summary.csv}";;
  plot-results) plot_results "${1:?log dir required}" "${2:-${1:?}/iperf_summary.csv}" "${3:-${1:?}/plots}";;
  status) status_nodes "${1:-$(all_nodes_csv)}";;
  -h|--help|help) usage;;
  *) echo "Unknown command: $cmd" >&2; usage; exit 1;;
esac
