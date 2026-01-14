import os.path

from ament_index_python.packages import get_package_share_directory

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution, TextSubstitution
from launch.conditions import IfCondition

from launch_ros.actions import Node


def generate_launch_description():
    package_path = get_package_share_directory('fast_lio')
    default_config_path = os.path.join(package_path, 'config')
    default_rviz_config_path = os.path.join(package_path, 'rviz', 'fastlio.rviz')

    use_sim_time = LaunchConfiguration('use_sim_time')
    config_path = LaunchConfiguration('config_path')
    config_file = LaunchConfiguration('config_file')
    rviz_use = LaunchConfiguration('rviz')
    rviz_cfg = LaunchConfiguration('rviz_cfg')

    # Logger Args
    log_odom = LaunchConfiguration("log_odom")
    csv_out = LaunchConfiguration("csv_out")
    tf_config = LaunchConfiguration("tf_config")

    declare_use_sim_time_cmd = DeclareLaunchArgument(
        'use_sim_time', default_value='false',
        description='Use simulation (Gazebo) clock if true'
    )
    declare_config_path_cmd = DeclareLaunchArgument(
        'config_path', default_value=default_config_path,
        description='Yaml config file path'
    )
    declare_config_file_cmd = DeclareLaunchArgument(
        'config_file', default_value='mid360.yaml',
        description='Config file'
    )
    declare_rviz_cmd = DeclareLaunchArgument(
        'rviz', default_value='true',
        description='Use RViz to monitor results'
    )
    declare_rviz_config_path_cmd = DeclareLaunchArgument(
        'rviz_cfg', default_value=default_rviz_config_path,
        description='RViz config file path'
    )

    declare_log_odom_cmd = DeclareLaunchArgument(
        'log_odom', default_value='false',
        description='Enable CSV trajectory logger'
    )
    declare_csv_out_cmd = DeclareLaunchArgument(
        'csv_out', default_value='odom.csv',
        description='Output CSV path'
    )
    declare_tf_config_cmd = DeclareLaunchArgument(
        'tf_config', default_value='',
        description='JSON file containing T^IMU_BASE (optional)'
    )

    fast_lio_node = Node(
        package='fast_lio',
        executable='fastlio_mapping',
        parameters=[PathJoinSubstitution([config_path, config_file]),
                    {'use_sim_time': use_sim_time}],
        output='screen'
    )
    odom_csv_logger_node = Node(
        package='fast_lio',
        executable='odom_csv_logger.py',
        name='odom_csv_logger',
        output='screen',
        condition=IfCondition(log_odom),
        arguments=[
            '--output', csv_out,
            '--tf_config', tf_config,
        ],
    )
    rviz_node = Node(
        package='rviz2',
        executable='rviz2',
        arguments=['-d', rviz_cfg],
        condition=IfCondition(rviz_use)
    )

    ld = LaunchDescription()
    ld.add_action(declare_use_sim_time_cmd)
    ld.add_action(declare_config_path_cmd)
    ld.add_action(declare_config_file_cmd)
    ld.add_action(declare_rviz_cmd)
    ld.add_action(declare_rviz_config_path_cmd)

    ld.add_action(declare_log_odom_cmd)
    ld.add_action(declare_csv_out_cmd)
    ld.add_action(declare_tf_config_cmd)

    ld.add_action(fast_lio_node)
    ld.add_action(odom_csv_logger_node)
    ld.add_action(rviz_node)

    return ld
