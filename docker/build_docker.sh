#!/usr/bin/env bash
# usage: ./docker/build_docker.sh [ROS_DISTRO]
set -euo pipefail

ROS_DISTRO="${1:-humble}"

docker build -f docker/Dockerfile --build-arg ROS_DISTRO="${ROS_DISTRO}" -t "fastlio-ros2:${ROS_DISTRO}" .