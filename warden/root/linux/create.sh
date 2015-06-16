#!/bin/bash

[ -n "$DEBUG" ] && set -o xtrace
set -o nounset
set -o errexit
shopt -s nullglob

cd $(dirname "${0}")

if [ $# -ne 1 ]; then
  echo "Usage: ${0} <instance_path>"
  exit 1
fi

target=${1}

if [ -d ${target} ]; then
  echo "\"${target}\" already exists, aborting..."
  exit 1
fi

#将root/linux/skeleton拷贝至对应的instance_id目录下，生成容器骨架
cp -r skeleton "${target}"   
#在新的mount namespace中执行setup.sh脚本
unshare -m "${target}"/setup.sh  
echo ${target}
