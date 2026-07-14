#!/bin/bash
# luci-app-limitpolice 一键部署脚本
# 用法: bash deploy.sh [host]    默认 root@192.168.1.1
#
# 流程:
#   1. tar 管道把 files/ 推到路由器的 /
#   2. 修可执行权限 + enable
#   3. 清 LuCI 编译缓存 + 重启 uhttpd
#   4. 重启 limitpolice 服务并打印 status
set -e

HOST="${1:-root@192.168.1.1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

if [ ! -d files ]; then
    echo "!! 找不到 files/ 目录，请从仓库根目录运行此脚本" >&2
    exit 1
fi

echo "==> 1/4 推送 files/ → $HOST:/"
tar czf - -C files . | ssh "$HOST" 'tar xzf - -C /'

echo "==> 2/4 修可执行权限 + enable"
ssh "$HOST" '
  chmod +x /etc/init.d/limitpolice /usr/sbin/limitpolice* 2>/dev/null
  /etc/init.d/limitpolice enable
'

echo "==> 3/4 清 LuCI 缓存 + 重启 uhttpd"
ssh "$HOST" '
  rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/
  /etc/init.d/uhttpd restart
'

echo "==> 4/4 重启 limitpolice + 打印状态"
ssh "$HOST" '
  /etc/init.d/limitpolice restart
  sleep 1
  echo "----- status -----"
  /etc/init.d/limitpolice status
  echo "----- daemon log (最近 10 行) -----"
  logread | grep -i limitpolice | tail -n 10
'

echo ""
echo "==> 完成。浏览器: http://192.168.1.1/cgi-bin/luci/admin/network/limitpolice"
echo "==> Traffic Report: http://192.168.1.1/cgi-bin/luci/admin/network/limitpolice/stats"
