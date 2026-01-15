ARG ROS_DISTRO=humble

FROM ros:${ROS_DISTRO}-ros-base

ARG ROS_DISTRO
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    tmux \
    libeigen3-dev \
    libpcl-dev \
    libpcap-dev \
    libspdlog-dev \
    libusb-1.0-0-dev \
    libyaml-cpp-dev \
    python3-colcon-common-extensions \
    python3-rosdep \
    python3-numpy \
    python3-scipy \
    ros-${ROS_DISTRO}-pcl-conversions \
    ros-${ROS_DISTRO}-pcl-ros \
    ros-${ROS_DISTRO}-rviz2 \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-c"]

# Build Livox SDK
RUN git clone https://github.com/Livox-SDK/Livox-SDK2.git /root/Livox-SDK2 \
 && cd /root/Livox-SDK2 \
 && curl -fsSL https://patch-diff.githubusercontent.com/raw/Livox-SDK/Livox-SDK2/pull/85.patch | git apply

WORKDIR /root/Livox-SDK2
RUN mkdir -p build \
    && cd build \
    && cmake .. -DCMAKE_CXX_FLAGS="-Wno-c++20-compat" \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig

# Build Livox ROS2 Driver ROS2 package
WORKDIR /root/livox_ws/src
RUN git clone --recursive --branch feature/use-standard-unit https://github.com/Ericsii/livox_ros_driver2.git

WORKDIR /root/livox_ws
RUN source /opt/ros/${ROS_DISTRO}/setup.bash \
    && colcon build --symlink-install

# Setup FAST-LIO workspace
WORKDIR /root/fastlio_ws

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN tee /etc/profile.d/fastlio.sh > /dev/null <<'EOF'
# Source ROS underlay
if [ -f /opt/ros/${ROS_DISTRO}/setup.bash ]; then
  source /opt/ros/${ROS_DISTRO}/setup.bash
fi
# Source Livox overlay
if [ -f /root/livox_ws/install/setup.bash ]; then
  source /root/livox_ws/install/setup.bash
fi
# Source FAST-LIO overlay (only if built)
if [ -f /root/fastlio_ws/install/setup.bash ]; then
  source /root/fastlio_ws/install/setup.bash
fi
EOF

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash", "-l"]
