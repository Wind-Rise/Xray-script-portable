#!/usr/bin/env bash

set -e

# 注释: 通过 Qwen3-Coder 生成。
# 脚本名称: geodata.sh
# 脚本仓库: https://github.com/zxcvos/Xray-script
# 作者: zxcvos, LinFly, GitHub Copilot
# 依赖: bash, curl, wget

# 获取当前脚本的目录和项目根目录的绝对路径
readonly CUR_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)" # 当前脚本所在目录
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录
readonly XRAY_DIR="${PROJECT_ROOT}/.xray-script/geodata"

GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/raw/release/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/raw/release/geosite.dat"

[ -d "$XRAY_DIR" ] || mkdir -p "$XRAY_DIR"
cd "$XRAY_DIR"

curl -L -o geoip.dat.new $GEOIP_URL
if [ $? -ne 0 ]; then
    rm -f geoip.dat.new
    exit 1
fi

curl -L -o geosite.dat.new $GEOSITE_URL
if [ $? -ne 0 ]; then
    rm -f geoip.dat.new geosite.dat.new
    exit 1
fi

rm -f geoip.dat geosite.dat

mv geoip.dat.new geoip.dat
mv geosite.dat.new geosite.dat

systemctl -q is-active xray && systemctl restart xray
