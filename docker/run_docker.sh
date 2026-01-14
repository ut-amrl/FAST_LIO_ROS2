#!/usr/bin/env bash
# usage: ./run_docker.sh [ros_distro]
set -euo pipefail

ROS_DISTRO="${1:-humble}"
shift || true

IMAGE="fastlio-ros2:${ROS_DISTRO}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CACHE_DIR="${ROOT_DIR}/.fastlio_cache/${ROS_DISTRO}"
mkdir -p "${CACHE_DIR}/build" "${CACHE_DIR}/install" "${CACHE_DIR}/log"

# Optional X11 support
X11_ARGS=()
if [ -n "${DISPLAY:-}" ] && [ -S /tmp/.X11-unix/X0 -o -d /tmp/.X11-unix ]; then
  X11_ARGS+=(
    -e "DISPLAY=${DISPLAY}"
    -e "QT_X11_NO_MITSHM=1"
    -v "/tmp/.X11-unix:/tmp/.X11-unix:rw"
  )
fi

docker run -it --rm --net=host \
  "${X11_ARGS[@]}" \
  -e USE_TMUX=1 \
  -e TMUX_SESSION="fastlio" \
  -v "${ROOT_DIR}:/root/fastlio_ws/src/fast_lio_ros2" \
  -v "${CACHE_DIR}/build:/root/fastlio_ws/build" \
  -v "${CACHE_DIR}/install:/root/fastlio_ws/install" \
  -v "${CACHE_DIR}/log:/root/fastlio_ws/log" \
  "$@" \
  "${IMAGE}" bash -l