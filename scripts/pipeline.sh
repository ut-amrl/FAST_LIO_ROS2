#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage:
  scripts/pipeline.sh run --config-file <path> (--bag-path <path> | --bag-list <txt>) [options]
  scripts/pipeline.sh build
  scripts/pipeline.sh help

Environment:
  ROS_DISTRO                 Optional (default: humble; override with ROS_DISTRO=jazzy)

Run options:
  --bag-path <path>          Single bag path on the host
  --bag-list <txt>           Text file with one bag path per line
  --config-file <path>       FAST-LIO config file (required)
  --tf-config <path>         Optional TF JSON for the CSV logger
  --rate <auto|num>          Bag play rate (default: auto, minimum fixed rate: 0.5)
  --queue-size <int>         ros2 bag read-ahead queue size (default: 5000)
  --rviz <true|false>        Launch rviz2 (default: false)
  --log-dir <path>           Host log dir for CSV output (default: logs)
  --build                    Build image before run
  --all-topics               Play all bag topics (default: false)
  --imu-topic <topic>        Override IMU topic from the config
  --lidar-topic <topic>      Override LiDAR topic from the config
  --no-xhost                 Skip xhost setup even with rviz:=true
  -h, --help                 Show this help
EOF
}

require_arg() {
  local opt="$1"
  local value="${2:-}"
  if [[ -z "${value}" ]]; then
    echo "Missing value for ${opt}" >&2
    print_usage >&2
    exit 2
  fi
}

trim_line() {
  local line="$1"
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s' "${line}"
}

resolve_candidate_path() {
  local input="$1"
  local base_dir="$2"
  if [[ "${input}" == /* ]]; then
    printf '%s\n' "${input}"
  else
    printf '%s/%s\n' "${base_dir}" "${input}"
  fi
}

canonicalize_existing_path() {
  local input="$1"
  local base_dir="$2"
  local candidate
  local resolved_dir

  candidate="$(resolve_candidate_path "${input}" "${base_dir}")"
  resolved_dir="$(cd -- "$(dirname -- "${candidate}")" && pwd -P)" || return 1
  printf '%s/%s\n' "${resolved_dir}" "$(basename -- "${candidate}")"
}

path_is_inside_repo() {
  local path="$1"
  [[ "${path}" == "${REPO_ROOT}" || "${path}" == "${REPO_ROOT}/"* ]]
}

repo_path_to_container() {
  local path="$1"
  if [[ "${path}" == "${REPO_ROOT}" ]]; then
    printf '/root/fastlio_ws/src/fast_lio_ros2\n'
  else
    printf '/root/fastlio_ws/src/fast_lio_ros2/%s\n' "${path#"${REPO_ROOT}/"}"
  fi
}

sanitize_identifier() {
  local raw="$1"
  local checksum

  checksum="$(printf '%s' "${raw}" | cksum | awk '{print $1}')"
  raw="${raw#/}"
  raw="${raw// /_}"
  raw="${raw//\//_}"
  raw="$(printf '%s' "${raw}" | tr -c 'A-Za-z0-9._-' '_')"
  raw="$(printf '%s' "${raw}" | tr -s '_')"
  raw="${raw#_}"
  raw="${raw%_}"

  if [[ -z "${raw}" ]]; then
    raw="bag"
  fi

  if [[ "${#raw}" -gt 120 ]]; then
    raw="${raw:0:120}"
  fi

  printf '%s_%s\n' "${raw}" "${checksum}"
}

validate_bool() {
  case "$1" in
    true|false) ;;
    *)
      echo "Expected true or false, got: $1" >&2
      exit 2
      ;;
  esac
}

validate_rate_mode() {
  if [[ "${RATE_MODE}" == "auto" ]]; then
    return 0
  fi

  set +e
  python3 - "${RATE_MODE}" <<'PY'
import sys

try:
    value = float(sys.argv[1])
except ValueError:
    raise SystemExit(1)

if value < 0.5:
    raise SystemExit(2)
PY
  local status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${status}" -eq 2 ]]; then
    echo "Rate must be at least 0.5" >&2
  else
    echo "Rate must be 'auto' or a numeric value" >&2
  fi
  exit 2
}

validate_queue_size() {
  if [[ ! "${QUEUE_SIZE}" =~ ^[0-9]+$ ]] || [[ "${QUEUE_SIZE}" == "0" ]]; then
    echo "Queue size must be a positive integer" >&2
    exit 2
  fi
}

STOP_REQUESTED=0
CURRENT_DOCKER_PID=""

handle_interrupt() {
  if [[ "${STOP_REQUESTED}" -eq 0 ]]; then
    echo "[run] interrupt received; stopping current run..."
  fi
  STOP_REQUESTED=1
  if [[ -n "${CURRENT_DOCKER_PID}" ]] && kill -0 "${CURRENT_DOCKER_PID}" >/dev/null 2>&1; then
    kill -INT "${CURRENT_DOCKER_PID}" >/dev/null 2>&1 || true
    sleep 1
    kill -TERM "${CURRENT_DOCKER_PID}" >/dev/null 2>&1 || true
  fi
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
COMPOSE_FILE="${REPO_ROOT}/docker/compose.yaml"

SUBCOMMAND="${1:-run}"
if [[ $# -gt 0 ]]; then
  shift
fi

ROS_DISTRO="${ROS_DISTRO:-humble}"

case "${SUBCOMMAND}" in
  help|-h|--help)
    print_usage
    exit 0
    ;;
  build)
    env ROS_DISTRO="${ROS_DISTRO}" docker compose -f "${COMPOSE_FILE}" build fastlio
    exit 0
    ;;
  run)
    ;;
  *)
    echo "Unknown command: ${SUBCOMMAND}" >&2
    print_usage >&2
    exit 2
    ;;
esac

BAG_PATH=""
BAG_LIST=""
CONFIG_FILE=""
TF_CONFIG=""
RATE_MODE="auto"
QUEUE_SIZE="5000"
RVIZ="false"
LOG_DIR="logs"
DO_BUILD="false"
ALL_TOPICS="false"
IMU_TOPIC_OVERRIDE=""
LIDAR_TOPIC_OVERRIDE=""
DO_XHOST="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bag-path)
      require_arg "$1" "${2:-}"
      BAG_PATH="$2"
      shift 2
      ;;
    --bag-list)
      require_arg "$1" "${2:-}"
      BAG_LIST="$2"
      shift 2
      ;;
    --config-file)
      require_arg "$1" "${2:-}"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --tf-config)
      require_arg "$1" "${2:-}"
      TF_CONFIG="$2"
      shift 2
      ;;
    --rate)
      require_arg "$1" "${2:-}"
      RATE_MODE="$2"
      shift 2
      ;;
    --queue-size)
      require_arg "$1" "${2:-}"
      QUEUE_SIZE="$2"
      shift 2
      ;;
    --rviz)
      require_arg "$1" "${2:-}"
      RVIZ="$2"
      shift 2
      ;;
    --log-dir)
      require_arg "$1" "${2:-}"
      LOG_DIR="$2"
      shift 2
      ;;
    --build)
      DO_BUILD="true"
      shift
      ;;
    --all-topics)
      ALL_TOPICS="true"
      shift
      ;;
    --imu-topic)
      require_arg "$1" "${2:-}"
      IMU_TOPIC_OVERRIDE="$2"
      shift 2
      ;;
    --lidar-topic)
      require_arg "$1" "${2:-}"
      LIDAR_TOPIC_OVERRIDE="$2"
      shift 2
      ;;
    --no-xhost)
      DO_XHOST="false"
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${CONFIG_FILE}" ]]; then
  echo "--config-file is required" >&2
  exit 2
fi

if [[ -z "${BAG_PATH}" && -z "${BAG_LIST}" ]]; then
  echo "One input is required: --bag-path or --bag-list" >&2
  exit 2
fi

if [[ -n "${BAG_PATH}" && -n "${BAG_LIST}" ]]; then
  echo "Use either --bag-path or --bag-list, not both" >&2
  exit 2
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi

validate_bool "${RVIZ}"
validate_rate_mode
validate_queue_size

CONFIG_HOST_PATH="$(canonicalize_existing_path "${CONFIG_FILE}" "${REPO_ROOT}")" || {
  echo "config file not found: ${CONFIG_FILE}" >&2
  exit 1
}
if [[ ! -f "${CONFIG_HOST_PATH}" ]]; then
  echo "config file not found: ${CONFIG_HOST_PATH}" >&2
  exit 1
fi

TF_HOST_PATH=""
if [[ -n "${TF_CONFIG}" ]]; then
  TF_HOST_PATH="$(canonicalize_existing_path "${TF_CONFIG}" "${REPO_ROOT}")" || {
    echo "tf config file not found: ${TF_CONFIG}" >&2
    exit 1
  }
  if [[ ! -f "${TF_HOST_PATH}" ]]; then
    echo "tf config file not found: ${TF_HOST_PATH}" >&2
    exit 1
  fi
fi

LOG_DIR_INPUT="$(resolve_candidate_path "${LOG_DIR}" "${REPO_ROOT}")"
mkdir -p "${LOG_DIR_INPUT}"
LOG_DIR_ABS="$(cd -- "${LOG_DIR_INPUT}" && pwd -P)"

if [[ "${DO_BUILD}" == "true" ]]; then
  env ROS_DISTRO="${ROS_DISTRO}" docker compose -f "${COMPOSE_FILE}" build fastlio
fi

if [[ "${RVIZ}" == "true" && "${DO_XHOST}" == "true" ]]; then
  if command -v xhost >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    xhost +si:localuser:root >/dev/null
  else
    echo "[warn] RViz requested but xhost or DISPLAY is unavailable. Continuing."
  fi
fi

CONFIG_CONTAINER_PATH=""
declare -a CONFIG_MOUNT_ARGS=()
if path_is_inside_repo "${CONFIG_HOST_PATH}"; then
  CONFIG_CONTAINER_PATH="$(repo_path_to_container "${CONFIG_HOST_PATH}")"
else
  CONFIG_CONTAINER_PATH="/input_config/$(basename -- "${CONFIG_HOST_PATH}")"
  CONFIG_MOUNT_ARGS=(-v "$(dirname -- "${CONFIG_HOST_PATH}"):/input_config:ro")
fi

TF_CONTAINER_PATH=""
declare -a TF_MOUNT_ARGS=()
if [[ -n "${TF_HOST_PATH}" ]]; then
  if path_is_inside_repo "${TF_HOST_PATH}"; then
    TF_CONTAINER_PATH="$(repo_path_to_container "${TF_HOST_PATH}")"
  else
    TF_CONTAINER_PATH="/input_tf/$(basename -- "${TF_HOST_PATH}")"
    TF_MOUNT_ARGS=(-v "$(dirname -- "${TF_HOST_PATH}"):/input_tf:ro")
  fi
fi

declare -a BAG_INPUTS=()
if [[ -n "${BAG_PATH}" ]]; then
  BAG_INPUTS+=("$(resolve_candidate_path "${BAG_PATH}" "${REPO_ROOT}")")
else
  BAG_LIST_PATH="$(canonicalize_existing_path "${BAG_LIST}" "${REPO_ROOT}")" || {
    echo "bag list file not found: ${BAG_LIST}" >&2
    exit 1
  }
  if [[ ! -f "${BAG_LIST_PATH}" ]]; then
    echo "bag list file not found: ${BAG_LIST_PATH}" >&2
    exit 1
  fi

  BAG_LIST_DIR="$(cd -- "$(dirname -- "${BAG_LIST_PATH}")" && pwd -P)"
  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    line="$(trim_line "${raw_line}")"
    if [[ -z "${line}" ]]; then
      continue
    fi
    BAG_INPUTS+=("$(resolve_candidate_path "${line}" "${BAG_LIST_DIR}")")
  done < "${BAG_LIST_PATH}"
fi

if [[ ${#BAG_INPUTS[@]} -eq 0 ]]; then
  echo "no bag entries found" >&2
  exit 1
fi

RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_LOG_DIR="${LOG_DIR_ABS}/${RUN_STAMP}"
mkdir -p "${RUN_LOG_DIR}"

read -r -d '' INNER_SCRIPT <<'EOF' || true
set -euo pipefail

log() {
  echo "[pipeline] $*"
}

safe_source() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "${path}"
    set -u 2>/dev/null || true
  fi
}

stop_process() {
  local pid="${1:-}"
  if [[ -z "${pid}" ]]; then
    return 0
  fi
  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill -INT "${pid}" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done
    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill -TERM "${pid}" >/dev/null 2>&1 || true
    fi
  fi
  wait "${pid}" >/dev/null 2>&1 || true
}

cleanup_processes() {
  stop_process "${BAG_PID:-}"
  BAG_PID=""
  stop_process "${LAUNCH_PID:-}"
  LAUNCH_PID=""
}

handle_interrupt() {
  cleanup_processes
  exit 130
}

wait_for_node() {
  local node_name="$1"
  local timeout_seconds="$2"
  local monitor_pid="${3:-}"
  local elapsed=0
  while (( elapsed < timeout_seconds )); do
    if ros2 node list 2>/dev/null | grep -qx "${node_name}"; then
      return 0
    fi
    if [[ -n "${monitor_pid}" ]] && ! kill -0 "${monitor_pid}" >/dev/null 2>&1; then
      wait "${monitor_pid}" || true
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

csv_has_rows() {
  local csv_path="$1"
  [[ -f "${csv_path}" ]] && [[ "$(wc -l < "${csv_path}")" -gt 1 ]]
}

read_config_topic() {
  local topic_key="$1"
  python3 - "${CONFIG_CONTAINER_PATH}" "${topic_key}" <<'PY'
import sys
import yaml

config_path, topic_key = sys.argv[1], sys.argv[2]
with open(config_path, "r", encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}

if not isinstance(data, dict):
    raise SystemExit(1)

value = None

common = data.get("common")
if isinstance(common, dict):
    value = common.get(topic_key)

if not value:
    root = data.get("/**")
    if isinstance(root, dict):
        ros_params = root.get("ros__parameters")
        if isinstance(ros_params, dict):
            common = ros_params.get("common")
            if isinstance(common, dict):
                value = common.get(topic_key)

if isinstance(value, str):
    value = value.strip()

if not value:
    raise SystemExit(1)
print(value)
PY
}

ensure_bag_readable() {
  local info_output

  set +e
  info_output="$(ros2 bag info "${BAG_PATH_IN_CONTAINER}" 2>&1)"
  local status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    return 0
  fi

  echo "${info_output}" >&2
  if grep -q "yaml-cpp: error" <<<"${info_output}"; then
    echo "Bag metadata is not readable by ROS_DISTRO=${ROS_DISTRO}." >&2
    echo "This bag was likely recorded with a newer rosbag2 metadata schema. Try ROS_DISTRO=jazzy for playback or convert the bag metadata for Humble." >&2
  fi
  return 1
}

start_launch_stack() {
  local config_dir
  local config_file
  local -a launch_cmd

  config_dir="$(dirname -- "${CONFIG_CONTAINER_PATH}")"
  config_file="$(basename -- "${CONFIG_CONTAINER_PATH}")"
  launch_cmd=(
    ros2 launch fast_lio mapping.launch.py
    config_path:="${config_dir}"
    config_file:="${config_file}"
    rviz:="${RVIZ}"
    log_odom:=true
    csv_out:="${LOG_CSV_CONTAINER_PATH}"
  )
  if [[ -n "${TF_CONFIG_CONTAINER_PATH:-}" ]]; then
    launch_cmd+=("tf_config:=${TF_CONFIG_CONTAINER_PATH}")
  fi

  "${launch_cmd[@]}" &
  LAUNCH_PID=$!

  if ! wait_for_node "/laser_mapping" 30 "${LAUNCH_PID}"; then
    echo "laser_mapping node did not become ready" >&2
    return 1
  fi

  if ! wait_for_node "/odom_csv_logger" 15 "${LAUNCH_PID}"; then
    echo "odom_csv_logger node did not become ready" >&2
    return 1
  fi
}

play_bag_once() {
  local rate="$1"
  local -a cmd=(
    ros2 bag play "${BAG_PATH_IN_CONTAINER}"
    --rate "${rate}"
    --read-ahead-queue-size "${QUEUE_SIZE}"
  )

  if [[ "${ALL_TOPICS}" != "true" ]]; then
    cmd+=(--topics "${IMU_TOPIC}" "${LIDAR_TOPIC}")
  fi

  log "playing bag at rate=${rate}"
  "${cmd[@]}" &
  BAG_PID=$!
  wait "${BAG_PID}"
  local bag_status=$?
  BAG_PID=""
  return "${bag_status}"
}

run_attempt() {
  local rate="$1"
  local bag_status

  cleanup_processes
  rm -f "${LOG_CSV_CONTAINER_PATH}"
  mkdir -p "$(dirname -- "${LOG_CSV_CONTAINER_PATH}")"

  if ! start_launch_stack; then
    cleanup_processes
    return 1
  fi

  set +e
  play_bag_once "${rate}"
  bag_status=$?
  set -e

  sleep 3
  stop_process "${LAUNCH_PID:-}"
  LAUNCH_PID=""

  if [[ "${bag_status}" -ne 0 ]]; then
    echo "ros2 bag play failed with exit ${bag_status}" >&2
    return "${bag_status}"
  fi

  if ! csv_has_rows "${LOG_CSV_CONTAINER_PATH}"; then
    echo "No odometry rows were logged to ${LOG_CSV_CONTAINER_PATH}" >&2
    return 10
  fi

  return 0
}

BAG_PID=""
LAUNCH_PID=""
ROS_DISTRO="${ROS_DISTRO:-humble}"

trap cleanup_processes EXIT
trap handle_interrupt INT TERM

safe_source "/opt/ros/${ROS_DISTRO}/setup.bash"
safe_source /root/livox_ws/install/setup.bash
safe_source /root/fastlio_ws/install/setup.bash

if [[ -z "${BAG_PATH_IN_CONTAINER:-}" || -z "${CONFIG_CONTAINER_PATH:-}" || -z "${LOG_CSV_CONTAINER_PATH:-}" ]]; then
  echo "BAG_PATH_IN_CONTAINER, CONFIG_CONTAINER_PATH, and LOG_CSV_CONTAINER_PATH are required" >&2
  exit 2
fi

if [[ ! -e "${BAG_PATH_IN_CONTAINER}" ]]; then
  echo "bag path not found: ${BAG_PATH_IN_CONTAINER}" >&2
  exit 1
fi

if [[ ! -f "${CONFIG_CONTAINER_PATH}" ]]; then
  echo "config file not found: ${CONFIG_CONTAINER_PATH}" >&2
  exit 1
fi

if [[ -n "${TF_CONFIG_CONTAINER_PATH:-}" ]] && [[ ! -f "${TF_CONFIG_CONTAINER_PATH}" ]]; then
  echo "tf config file not found: ${TF_CONFIG_CONTAINER_PATH}" >&2
  exit 1
fi

ensure_bag_readable

if [[ "${ALL_TOPICS}" != "true" ]]; then
  if [[ -n "${IMU_TOPIC_OVERRIDE:-}" ]]; then
    IMU_TOPIC="${IMU_TOPIC_OVERRIDE}"
  else
    IMU_TOPIC="$(read_config_topic "imu_topic")" || {
      echo "Failed to read imu_topic from ${CONFIG_CONTAINER_PATH} (supported layouts: common.imu_topic or /**.ros__parameters.common.imu_topic)" >&2
      exit 1
    }
  fi

  if [[ -n "${LIDAR_TOPIC_OVERRIDE:-}" ]]; then
    LIDAR_TOPIC="${LIDAR_TOPIC_OVERRIDE}"
  else
    LIDAR_TOPIC="$(read_config_topic "lid_topic")" || {
      echo "Failed to read lid_topic from ${CONFIG_CONTAINER_PATH} (supported layouts: common.lid_topic or /**.ros__parameters.common.lid_topic)" >&2
      exit 1
    }
  fi
fi

log "ROS_DISTRO=${ROS_DISTRO}"
log "bag_path=${BAG_PATH_IN_CONTAINER}"
log "config_file=${CONFIG_CONTAINER_PATH}"
log "log_csv=${LOG_CSV_CONTAINER_PATH}"
if [[ -n "${TF_CONFIG_CONTAINER_PATH:-}" ]]; then
  log "tf_config=${TF_CONFIG_CONTAINER_PATH}"
fi

if [[ "${ALL_TOPICS}" == "true" ]]; then
  log "playing all bag topics"
else
  log "imu_topic=${IMU_TOPIC}"
  log "lidar_topic=${LIDAR_TOPIC}"
fi

if [[ "${RATE_MODE}" == "auto" ]]; then
  set +e
  run_attempt "1.0"
  attempt_status=$?
  set -e

  if [[ "${attempt_status}" -eq 0 ]]; then
    exit 0
  fi

  if [[ "${attempt_status}" -ne 10 ]]; then
    exit "${attempt_status}"
  fi

  log "retrying with rate=0.5 after empty odometry log"
  run_attempt "0.5"
  exit $?
fi

run_attempt "${RATE_MODE}"
EOF

echo "[run] ROS_DISTRO=${ROS_DISTRO}"
echo "[run] config_file=${CONFIG_HOST_PATH}"
if [[ -n "${TF_HOST_PATH}" ]]; then
  echo "[run] tf_config=${TF_HOST_PATH}"
fi
echo "[run] total_bags=${#BAG_INPUTS[@]}"
echo "[run] logs=${RUN_LOG_DIR}"

trap handle_interrupt INT TERM

declare -i success_count=0
declare -i fail_count=0
declare -a failed_items=()

for raw_bag_path in "${BAG_INPUTS[@]}"; do
  if [[ "${STOP_REQUESTED}" -eq 1 ]]; then
    break
  fi

  if [[ -e "${raw_bag_path}" ]]; then
    bag_host_path="$(canonicalize_existing_path "${raw_bag_path}" "/")"
  else
    bag_host_path="${raw_bag_path}"
  fi

  if [[ ! -e "${bag_host_path}" ]]; then
    fail_count+=1
    failed_items+=("${bag_host_path}")
    echo "[run] bag path not found: ${bag_host_path}" >&2
    continue
  fi

  bag_id="$(sanitize_identifier "${bag_host_path}")"
  csv_name="${bag_id}_trajectory.csv"
  csv_host_path="${RUN_LOG_DIR}/${csv_name}"
  csv_container_path="/logs/${RUN_STAMP}/${csv_name}"

  bag_parent_dir="$(dirname -- "${bag_host_path}")"
  bag_basename="$(basename -- "${bag_host_path}")"
  bag_container_path="/input_bag/${bag_basename}"

  docker_args=(
    compose -f "${COMPOSE_FILE}" run --rm
    -e USE_TMUX=0
    -e "BAG_PATH_IN_CONTAINER=${bag_container_path}"
    -e "CONFIG_CONTAINER_PATH=${CONFIG_CONTAINER_PATH}"
    -e "LOG_CSV_CONTAINER_PATH=${csv_container_path}"
    -e "RATE_MODE=${RATE_MODE}"
    -e "QUEUE_SIZE=${QUEUE_SIZE}"
    -e "RVIZ=${RVIZ}"
    -e "ALL_TOPICS=${ALL_TOPICS}"
    -e "IMU_TOPIC_OVERRIDE=${IMU_TOPIC_OVERRIDE}"
    -e "LIDAR_TOPIC_OVERRIDE=${LIDAR_TOPIC_OVERRIDE}"
    -v "${LOG_DIR_ABS}:/logs"
    -v "${bag_parent_dir}:/input_bag:ro"
  )

  if [[ -n "${TF_CONTAINER_PATH}" ]]; then
    docker_args+=(-e "TF_CONFIG_CONTAINER_PATH=${TF_CONTAINER_PATH}")
  fi

  if [[ ${#CONFIG_MOUNT_ARGS[@]} -gt 0 ]]; then
    docker_args+=("${CONFIG_MOUNT_ARGS[@]}")
  fi

  if [[ ${#TF_MOUNT_ARGS[@]} -gt 0 ]]; then
    docker_args+=("${TF_MOUNT_ARGS[@]}")
  fi

  docker_args+=(fastlio bash -lc "${INNER_SCRIPT}")

  echo "[run] bag=${bag_host_path}"
  echo "[run] csv=${csv_host_path}"

  set +e
  env ROS_DISTRO="${ROS_DISTRO}" docker "${docker_args[@]}" &
  CURRENT_DOCKER_PID=$!
  wait "${CURRENT_DOCKER_PID}"
  bag_status=$?
  CURRENT_DOCKER_PID=""
  set -e

  if [[ "${STOP_REQUESTED}" -eq 1 || "${bag_status}" -eq 130 || "${bag_status}" -eq 143 ]]; then
    STOP_REQUESTED=1
    echo "[run] interrupted: ${bag_host_path}" >&2
    break
  fi

  if [[ "${bag_status}" -eq 0 ]]; then
    success_count+=1
    echo "[run] csv saved: ${csv_host_path}"
  else
    fail_count+=1
    failed_items+=("${bag_host_path}")
    echo "[run] bag failed (exit=${bag_status}): ${bag_host_path}" >&2
  fi
done

trap - INT TERM

if [[ "${STOP_REQUESTED}" -eq 1 ]]; then
  echo "[summary] interrupted by user"
  echo "[summary] success=${success_count} fail=${fail_count}"
  exit 130
fi

echo "[summary] success=${success_count} fail=${fail_count}"
if [[ "${fail_count}" -gt 0 ]]; then
  for item in "${failed_items[@]}"; do
    echo "[summary] failed=${item}"
  done
  exit 1
fi
