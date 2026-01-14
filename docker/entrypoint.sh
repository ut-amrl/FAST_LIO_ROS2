#!/usr/bin/env bash
set -eo pipefail

log() { echo "[entrypoint] $*"; }

safe_source() {
  local f="$1"
  if [ -f "$f" ]; then
    set +u
    # shellcheck disable=SC1090
    source "$f"
    set -u 2>/dev/null || true
  fi
}

# Prefer runtime ROS_DISTRO from the base image; fallback to build-time arg passed as env
ros_distro="${ROS_DISTRO:-humble}"
ros_setup="/opt/ros/${ros_distro}/setup.bash"

log "starting (ROS_DISTRO=${ros_distro})"

# Underlays
if [ -f "$ros_setup" ]; then
  safe_source "$ros_setup"
else
  log "ERROR: ROS setup not found at $ros_setup"
  exec "$@"
fi

safe_source /root/livox_ws/install/setup.bash

# Workspace sanity
ws="/root/fastlio_ws"
if [ ! -d "${ws}/src" ]; then
  log "ERROR: ${ws}/src does not exist"
  log "Mount your repo into ${ws}/src/<pkg> (e.g. -v \"\$(pwd):${ws}/src/fast_lio_ros2\")"
  exec "$@"
fi

if [ -z "$(ls -A "${ws}/src" 2>/dev/null)" ]; then
  log "WARNING: ${ws}/src is empty; skipping build"
  exec "$@"
fi

# Rebuild decision:
# - no install => build
# - src newer than install => build
install_setup="${ws}/install/setup.bash"
need_build=0
if [ ! -f "$install_setup" ]; then
  need_build=1
elif find "${ws}/src" -type f -newer "$install_setup" -print -quit | grep -q .; then
  need_build=1
fi

if [ "$need_build" -eq 0 ]; then
  log "FAST-LIO already built; sourcing overlay"
  safe_source "$install_setup"
else
  log "building FAST-LIO"

  cd "$ws"
  colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release

  log "build done; sourcing overlay"
  safe_source "$install_setup"
fi

# Tmux session
if [ "${USE_TMUX:-0}" = "1" ]; then
  SESSION="${TMUX_SESSION:-fastlio}"

  # If no explicit command was provided, open tmux
  if [ $# -eq 0 ] || { [ "$1" = "bash" ] && [ $# -eq 1 ]; } || { [ "$1" = "bash" ] && [ "${2:-}" = "-l" ]; }; then
    log "starting tmux session: ${SESSION}"
    exec tmux new -A -s "${SESSION}"
  fi
fi

exec "$@"
