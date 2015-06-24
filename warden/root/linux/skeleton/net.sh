#!/bin/bash

[ -n "$DEBUG" ] && set -o xtrace
set -o nounset
set -o errexit
shopt -s nullglob

cd $(dirname "${0}")

source ./etc/config

filter_forward_chain="warden-forward"
filter_default_chain="warden-default"
filter_instance_prefix="warden-i-"
filter_instance_chain="${filter_instance_prefix}${id}"
filter_instance_log_chain="${filter_instance_prefix}${id}-log"
nat_prerouting_chain="warden-prerouting"
nat_instance_prefix="warden-i-"
nat_instance_chain="${filter_instance_prefix}${id}"

external_ip=$(ip route get 8.8.8.8 | sed 's/.*src\s\(.*\)\s/\1/;tx;d;:x')

#删除forward chain和instance chain
function teardown_filter() {
  # Prune forward chain
  #查询filter_forward_chain中是否已有该instance对应规则，如果存在，删除之
  iptables -S ${filter_forward_chain} 2> /dev/null |
    grep "\-g ${filter_instance_chain}\b" |
    sed -e "s/-A/-D/" |
    xargs --no-run-if-empty --max-lines=1 iptables

  # Flush and delete instance chain
  #查了下iptables -F -X 都是删除chain中规则的意思，不知道这里为什么写两遍
  iptables -F ${filter_instance_chain} 2> /dev/null || true
  iptables -X ${filter_instance_chain} 2> /dev/null || true
  iptables -F ${filter_instance_log_chain} 2> /dev/null || true
  iptables -X ${filter_instance_log_chain} 2> /dev/null || true
}

function setup_filter() {
  teardown_filter

  # Create instance chain
  #新建instance chain
  iptables -N ${filter_instance_chain}
  #在instance chain中添加跳转至default chain的规则
  iptables -A ${filter_instance_chain} \
    --goto ${filter_default_chain}

  # Bind instance chain to forward chain
  # 在warden forward chain中添加规则，该规则指定从${network_host_iface}网卡(即 w-intanceid-0)
  # 流入的数据都跳转至${filter_instance_chain}
  iptables -I ${filter_forward_chain} 2 \
    --in-interface ${network_host_iface} \
    --goto ${filter_instance_chain}

  # Create instance log chain
  iptables -N ${filter_instance_log_chain}
  iptables -A ${filter_instance_log_chain} \
    -p tcp -m conntrack --ctstate NEW,UNTRACKED,INVALID -j LOG --log-prefix "${filter_instance_chain} "
  iptables -A ${filter_instance_log_chain} \
    --jump RETURN
}

function teardown_nat() {
  # Prune prerouting chain
  iptables -t nat -S ${nat_prerouting_chain} 2> /dev/null |
    grep "\-j ${nat_instance_chain}\b" |
    sed -e "s/-A/-D/" |
    xargs --no-run-if-empty --max-lines=1 iptables -t nat

  # Flush and delete instance chain
  iptables -t nat -F ${nat_instance_chain} 2> /dev/null || true
  iptables -t nat -X ${nat_instance_chain} 2> /dev/null || true
}

function setup_nat() {
  teardown_nat

  # Create instance chain
  iptables -t nat -N ${nat_instance_chain}

  # Bind instance chain to prerouting chain
  iptables -t nat -A ${nat_prerouting_chain} \
    --jump ${nat_instance_chain}
}

# Lock execution
mkdir -p ../tmp
exec 3> ../tmp/$(basename $0).lock
flock -x -w 10 3

case "${1}" in
  "setup")
    setup_filter
    setup_nat

    ;;

  "teardown")
    teardown_filter
    teardown_nat

    ;;

  "in")
    if [ -z "${HOST_PORT:-}" ]; then
      echo "Please specify HOST_PORT..." 1>&2
      exit 1
    fi

    if [ -z "${CONTAINER_PORT:-}" ]; then
      echo "Please specify CONTAINER_PORT..." 1>&2
      exit 1
    fi

    iptables -t nat -A ${nat_instance_chain} \
      --protocol tcp \
      --destination "${external_ip}" \
      --destination-port "${HOST_PORT}" \
      --jump DNAT \
      --to-destination "${network_container_ip}:${CONTAINER_PORT}"

    ;;

  "out")
    if [ "${PROTOCOL:-}" != "icmp" ] && [ -z "${NETWORK:-}" ] && [ -z "${PORTS:-}" ]; then
      echo "Please specify NETWORK and/or PORTS..." 1>&2
      exit 1
    fi

    opts="--protocol ${PROTOCOL:-tcp}"

    if [ -n "${NETWORK:-}" ]; then
      case ${NETWORK} in
        *-*)
          opts="${opts} -m iprange --dst-range ${NETWORK}"
          ;;
        *)
          opts="${opts} --destination ${NETWORK}"
          ;;
      esac
    fi

    if [ -n "${PORTS:-}" ]; then
      opts="${opts} --destination-port ${PORTS}"
    fi

    if [ "${PROTOCOL}" == "icmp" ]; then
      if [ -n "${ICMP_TYPE}" ]; then
        opts="${opts} --icmp-type ${ICMP_TYPE}"
        if [ -n "${ICMP_CODE}" ]; then
          opts="${opts}/${ICMP_CODE}"
        fi
      fi
    fi

    if [ "${LOG}"  == "true" ]; then
      target="--goto ${filter_instance_log_chain}"
    else
      target="--jump RETURN"
    fi

    iptables -I ${filter_instance_chain} 1 ${opts} ${target}

    ;;
  "get_ingress_info")
    if [ -z "${ID:-}" ]; then
      echo "Please specify container ID..." 1>&2
      exit 1
    fi
    tc filter show dev w-${ID}-0 parent ffff:

    ;;
  "get_egress_info")
    if [ -z "${ID:-}" ]; then
      echo "Please specify container ID..." 1>&2
      exit 1
    fi
    tc qdisc show dev w-${ID}-0

    ;;
  *)
    echo "Unknown command: ${1}" 1>&2
    exit 1

    ;;
esac
