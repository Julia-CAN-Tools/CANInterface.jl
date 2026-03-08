#!/bin/bash
modprobe vcan
ip link add dev vcan0 type vcan
ip link add dev vcan1 type vcan
ip link add dev vcan2 type vcan
ip link add dev vcan3 type vcan
ip link add dev vcan4 type vcan
ip link add dev vcan5 type vcan
ip link add dev vcan6 type vcan
ip link add dev vcan7 type vcan
ip link set vcan0 up
ip link set vcan1 up
ip link set vcan2 up
ip link set vcan3 up
ip link set vcan4 up
ip link set vcan5 up
ip link set vcan6 up
ip link set vcan7 up
