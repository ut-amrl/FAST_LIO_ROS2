#!/usr/bin/env python3

import csv
import argparse
import json

import numpy as np
from scipy.spatial.transform import Rotation as R

import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry


def load_transform_matrix(config_file, matrix_name, logger):
    """Load transformation matrix from config file or use identity."""
    try:
        with open(config_file, "r") as f:
            config = json.load(f)
            if matrix_name in config:
                matrix_data = config[matrix_name]
                if isinstance(matrix_data, list) and len(matrix_data) == 16:
                    return np.array(matrix_data).reshape(4, 4)
                else:
                    logger.warning(
                        f"Invalid matrix format for {matrix_name}, using identity"
                    )
            else:
                logger.warning(
                    f"Matrix {matrix_name} not found in config, using identity"
                )
    except (FileNotFoundError, json.JSONDecodeError) as e:
        logger.warning(f"Config file error: {e}, using identities")

    return np.eye(4)


class OdomCSVLogger(Node):
    def __init__(self, output_path="odom.csv", tf_config=None, topic="Odometry"):
        super().__init__("odom_csv_logger")

        self.first_write = True
        self.write_count = 0
        self.csv_file = open(output_path, "w", newline="")
        self.writer = None

        # Load transformation matrices
        self.T_IMU_BASE = np.eye(4)

        if tf_config:
            self.T_IMU_BASE = load_transform_matrix(
                tf_config, "T^IMU_BASE", self.get_logger()
            )
        else:
            self.get_logger().info("No TF config provided, using identity for T^IMU_BASE")
        self.T_BASE_IMU = np.linalg.inv(self.T_IMU_BASE)

        self.subscription = self.create_subscription(Odometry, topic, self.callback, 10)

        self.get_logger().info(f"OdomCSVLogger started, saving to {output_path}")
        self.get_logger().info(f"T^IMU_BASE:\n{self.T_IMU_BASE}")
        self.get_logger().info(f"Subscribed to topic: {topic}")

    def callback(self, msg: Odometry):
        p = msg.pose.pose.position
        q = msg.pose.pose.orientation

        T_imu0_imu = np.eye(4)
        T_imu0_imu[:3, 3] = [p.x, p.y, p.z]
        T_imu0_imu[:3, :3] = R.from_quat([q.x, q.y, q.z, q.w]).as_matrix()

        pose = self.T_BASE_IMU @ T_imu0_imu @ self.T_IMU_BASE
        quat = R.from_matrix(pose[:3, :3]).as_quat()

        # ROS 2 time: sec + nanosec
        timestamp = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9

        data = {
            "timestamp": timestamp,
            "x": pose[0, 3],
            "y": pose[1, 3],
            "z": pose[2, 3],
            "qx": quat[0],
            "qy": quat[1],
            "qz": quat[2],
            "qw": quat[3],
        }

        if self.first_write:
            self.writer = csv.DictWriter(self.csv_file, fieldnames=list(data.keys()))
            self.writer.writeheader()
            self.first_write = False

        formatted = {k: f"{v:.8f}" for k, v in data.items()}
        self.writer.writerow(formatted)

        self.write_count += 1
        if self.write_count % 100 == 0:
            self.csv_file.flush()

    def shutdown(self):
        self.get_logger().info("Shutting down OdomCSVLogger...")
        try:
            # FORCE FLUSH: Writes the remaining 1-99 rows in the buffer to disk
            self.csv_file.flush()
            self.csv_file.close()
            self.get_logger().info(f"Success. Total {self.write_count} poses saved to CSV.")
        except Exception as e:
            self.get_logger().warning(f"Error closing CSV file: {e}")


def main(args, ros_args):
    rclpy.init(args=ros_args)
    node = OdomCSVLogger(args.output, args.tf_config, args.topic)

    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.shutdown()
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--topic", type=str, default="Odometry", help="Odometry topic to subscribe to"
    )
    parser.add_argument(
        "--tf_config",
        type=str,
        help="Path to JSON config file with transformation matrices",
    )
    parser.add_argument(
        "--output", type=str, default="odom.csv", help="Path to output CSV file"
    )
    args, ros_args = parser.parse_known_args()

    main(args, ros_args)
