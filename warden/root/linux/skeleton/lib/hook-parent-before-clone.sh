#!/bin/bash

[ -n "$DEBUG" ] && set -o xtrace
set -o nounset
set -o errexit
shopt -s nullglob

cd $(dirname $0)/../
# 文件系统相关函数生效
source ./lib/common.sh
# 设置文件系统格式
setup_fs
# 拷贝wshd可执文件并修改权限 wshd属root用户
cp bin/wshd mnt/sbin/wshd
chmod 700 mnt/sbin/wshd
