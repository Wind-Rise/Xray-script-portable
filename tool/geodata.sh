#!/usr/bin/env bash

set -e

# 脚本名称: geodata.sh
# 功能描述: 从配置文件指定的 URL 下载 GeoIP/GeoSite 数据并更新 Xray。
# 依赖: bash, curl, jq

readonly CUR_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)"
readonly XRAY_DIR="${PROJECT_ROOT}/.xray-script/geodata"
readonly XRAY_BIN="${PROJECT_ROOT}/.xray-script/bin/xray"
readonly SCRIPT_CONFIG_PATH="${PROJECT_ROOT}/.xray-script/config.json"

GEOIP_URL="$(jq -r '.urls.geodata_geoip' "${SCRIPT_CONFIG_PATH}")"
GEOSITE_URL="$(jq -r '.urls.geodata_geosite' "${SCRIPT_CONFIG_PATH}")"

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

systemctl -q is-active xsp-xray 2>/dev/null && systemctl restart xsp-xray 2>/dev/null || true
