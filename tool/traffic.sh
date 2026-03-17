#!/usr/bin/env bash

# 注释: 通过 Qwen3-Coder 生成。
# 脚本名称: traffic.sh
# 脚本仓库: https://github.com/zxcvos/Xray-script
# 作者: zxcvos, LinFly, GitHub Copilot
# 依赖: bash

readonly CUR_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)" # 当前脚本所在目录
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录
readonly _XRAY="${PROJECT_ROOT}/.xray-script/bin/xray"
readonly _APISERVER=127.0.0.1:32768

function print_error() {
    echo "[ERROR] $*" >&2
    exit 1
}

if [[ ! -x "${_XRAY}" ]]; then
    print_error "Xray binary not found in project path: ${_XRAY}"
fi

apidata() {
    local ARGS=
    if [[ $1 == "reset" ]]; then
        ARGS="-reset=true"
    fi
    $_XRAY api statsquery --server=$_APISERVER "${ARGS}" |
        awk '{
        if (match($1, /"name":/)) {
            f=1; gsub(/^"|link"|,$/, "", $2);
            split($2, p,  ">>>");
            printf "%s:%s->%s\t", p[1],p[2],p[4];
        }
        else if (match($1, /"value":/) && f){
          f = 0;
          gsub(/"/, "", $2);
          printf "%.0f\n", $2;
        }
        else if (match($0, /}/) && f) { f = 0; print 0; }
    }'
}

print_sum() {
    local DATA="$1"
    local PREFIX="$2"
    local SORTED=$(echo "$DATA" | grep "^${PREFIX}" | sort -r)
    local SUM=$(echo "$SORTED" | awk '
        /->up/{us+=$2}
        /->down/{ds+=$2}
        END{
            printf "SUM->up:\t%.0f\nSUM->down:\t%.0f\nSUM->TOTAL:\t%.0f\n", us, ds, us+ds;
        }')
    echo -e "${SORTED}\n${SUM}" |
        numfmt --field=2 --suffix=B --to=iec |
        column -t
}

DATA=$(apidata $1)
echo "------------Inbound----------"
print_sum "$DATA" "inbound"
echo "-----------------------------"
echo "------------Outbound----------"
print_sum "$DATA" "outbound"
echo "-----------------------------"
echo
echo "-------------User------------"
print_sum "$DATA" "user"
echo "-----------------------------"
