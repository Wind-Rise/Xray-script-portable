#!/usr/bin/env bash
# =============================================================================
# 脚本名称: install.sh
# 功能描述: Xray-script-portable 项目的安装引导脚本。
#           负责检查和安装系统依赖、初始化配置、设置语言以及启动主菜单。
#           所有配置文件均保存在项目本地，不从远程下载。
# 时间: 2025-07-25
# 版本: 1.0.0
# 依赖: bash, curl, wget, git, jq, sed, awk, grep
# 配置:
#   - ${PROJECT_ROOT}/config.json: 项目默认配置模板 (随项目分发)
#   - ${SCRIPT_CONFIG_DIR}/config.json: 运行时配置文件 (从本地模板复制)
# Xray 官方链接:
#   - Xray-core: https://github.com/XTLS/Xray-core
#   - REALITY: https://github.com/XTLS/REALITY
#   - XHTTP: https://github.com/XTLS/Xray-core/discussions/4113
# =============================================================================

# set -Eeuxo pipefail

# --- 环境与常量设置 ---
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:/snap/bin
export PATH

readonly GREEN='\033[32m'
readonly YELLOW='\033[33m'
readonly RED='\033[31m'
readonly NC='\033[0m'

readonly CUR_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
readonly CUR_FILE="$(basename "$0")"

declare PROJECT_ROOT=''
declare PROJECT_ROOT_OVERRIDE=''
declare SCRIPT_CONFIG_DIR=''
declare SCRIPT_CONFIG_PATH=''

declare -A I18N_DATA=(
    ['error']='错误'
    ['root']='请使用 root 权限运行该脚本'
    ['supported']='不支持当前系统，请切换到 Ubuntu 16+、Debian 9+、CentOS 7+'
    ['ubuntu']='不支持当前版本，请切换到 Ubuntu 16+ 重试'
    ['debian']='不支持当前版本，请切换到 Debian 9+ 重试'
    ['centos']='不支持当前版本，请切换到 CentOS 7+ 重试'
    ['tip']='更新提示'
    ['new']='发现有新脚本, 是否更新'
    ['now']='是否更新 [Y/n] '
    ['promptly']='请及时更新脚本'
    ['completed']='更新完成'
    ['download']='正在下载'
    ['failed']='下载失败'
    ['downloaded']='文件已下载到'
)
declare PROJECT_ROOT=''
declare I18N_DIR=''
declare CORE_DIR=''
declare SERVICE_DIR=''
declare CONFIG_DIR=''
declare TOOL_DIR=''
declare QUICK_INSTALL=''
declare SCRIPT_CONFIG=''
declare LANG_PARAM=''
declare FORCE_CHECK_DEPS=0

function _os() {
    local os=""
    if [[ -f "/etc/debian_version" ]]; then
        source /etc/os-release && os="${ID}"
        printf -- "%s" "${os}" && return
    fi
    if [[ -f "/etc/redhat-release" ]]; then
        os="centos"
        printf -- "%s" "${os}" && return
    fi
}

function _os_full() {
    if [[ -f /etc/redhat-release ]]; then
        awk '{print ($1,$3~/^[0-9]/?$3:$4)}' /etc/redhat-release && return
    fi
    if [[ -f /etc/os-release ]]; then
        awk -F'[= "]' '/PRETTY_NAME/{print $3,$4,$5}' /etc/os-release && return
    fi
    if [[ -f /etc/lsb-release ]]; then
        awk -F'[="]+' '/DESCRIPTION/{print $2}' /etc/lsb-release && return
    fi
}

function _os_ver() {
    local main_ver="$(echo $(_os_full) | grep -oE "[0-9.]+")"
    printf -- "%s" "${main_ver%%.*}"
}

function cmd_exists() {
    local cmd="$1"
    if eval type type >/dev/null 2>&1; then
        eval type "$cmd" >/dev/null 2>&1
    elif command >/dev/null 2>&1; then
        command -v "$cmd" >/dev/null 2>&1
    else
        which "$cmd" >/dev/null 2>&1
    fi
}

function parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --lang=*)
            LANG_PARAM="${1}"
            ;;
        --check-deps)
            FORCE_CHECK_DEPS=1
            ;;
        esac
        shift
    done
}

function load_i18n() {
    local lang="${LANG_PARAM#*=}"

    if [[ -z "${lang}" && -f "${SCRIPT_CONFIG_PATH}" ]]; then
        if cmd_exists "jq"; then
            lang="$(jq -r '.language' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"
        fi
    fi

    if [[ "$lang" == "auto" ]]; then
        lang=$(echo "$LANG" | cut -d'_' -f1)
    fi

    if [[ "$lang" == "en" ]]; then
        I18N_DATA=(
            ['error']='Error'
            ['root']='This script must be run as root'
            ['supported']='Not supported OS'
            ['ubuntu']='Not supported OS, please change to Ubuntu 18+ and try again.'
            ['debian']='Not supported OS, please change to Debian 9+ and try again.'
            ['centos']='Not supported OS, please change to CentOS 7+ and try again.'
            ['tip']='Update Notice'
            ['new']='A new version of the script is available. Do you want to update?'
            ['now']='Update now? [Y/n]'
            ['promptly']='Please update the script promptly.'
            ['completed']='Update completed'
            ['download']='Downloading'
            ['failed']='Download failed'
            ['downloaded']='The file has been downloaded to'
        )
    fi
}

function _error() {
    printf "${RED}[${I18N_DATA['error']}] ${NC}"
    printf -- "%s" "$@"
    printf "\n"
    exit 1
}

function check_os() {
    case "$(_os)" in
    centos)
        if [[ "$(_os_ver)" -lt 7 ]]; then
            _error "${I18N_DATA['centos']}"
        fi
        ;;
    ubuntu)
        if [[ "$(_os_ver)" -lt 16 ]]; then
            _error "${I18N_DATA['ubuntu']}"
        fi
        ;;
    debian)
        if [[ "$(_os_ver)" -lt 9 ]]; then
            _error "${I18N_DATA['debian']}"
        fi
        ;;
    *)
        _error "${I18N_DATA['supported']}"
        ;;
    esac
}

function check_dependencies() {
    local packages=("ca-certificates" "openssl" "curl" "wget" "git" "jq" "tzdata" "qrencode" "socat")
    local missing_packages=()

    case "$(_os)" in
    centos)
        packages+=("crontabs" "util-linux" "iproute" "procps-ng" "bind-utils")
        for pkg in "${packages[@]}"; do
            if ! rpm -q "$pkg" &>/dev/null; then
                missing_packages+=("$pkg")
            fi
        done
        ;;
    debian | ubuntu)
        packages+=("cron" "bsdmainutils" "iproute2" "procps" "dnsutils")
        for pkg in "${packages[@]}"; do
            if ! dpkg -s "$pkg" &>/dev/null; then
                missing_packages+=("$pkg")
            fi
        done
        ;;
    esac

    [[ ${#missing_packages[@]} -eq 0 ]]
}

function install_dependencies() {
    local packages=("ca-certificates" "openssl" "curl" "wget" "git" "jq" "tzdata" "qrencode" "socat")

    case "$(_os)" in
    centos)
        packages+=("crontabs" "util-linux" "iproute" "procps-ng" "bind-utils")
        if cmd_exists "dnf"; then
            dnf update -y
            dnf install -y dnf-plugins-core
            dnf update -y
            for pkg in "${packages[@]}"; do
                dnf install -y ${pkg}
            done
        else
            yum update -y
            yum install -y epel-release yum-utils
            yum update -y
            for pkg in "${packages[@]}"; do
                yum install -y ${pkg}
            done
        fi
        ;;
    ubuntu | debian)
        packages+=("cron" "bsdmainutils" "iproute2" "procps" "dnsutils")
        apt update -y
        for pkg in "${packages[@]}"; do
            apt install -y ${pkg}
        done
        ;;
    esac
}

function init_local_config() {
    local default_config="${PROJECT_ROOT}/config.json"
    if [[ ! -f "${SCRIPT_CONFIG_PATH}" ]]; then
        if [[ -f "${default_config}" ]]; then
            cp -f "${default_config}" "${SCRIPT_CONFIG_PATH}"
        else
            echo '{}' >"${SCRIPT_CONFIG_PATH}"
        fi
    fi
}

function main() {
    parse_args "$@"

    PROJECT_ROOT="${CUR_DIR}"
    SCRIPT_CONFIG_DIR="${PROJECT_ROOT}/.xray-script"
    SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_DIR}/config.json"

    if [[ ! -d "${SCRIPT_CONFIG_DIR}" ]]; then
        mkdir -p "${SCRIPT_CONFIG_DIR}"
    fi
    mkdir -p "${SCRIPT_CONFIG_DIR}/xray" "${SCRIPT_CONFIG_DIR}/acme.sh" >/dev/null 2>&1 || true

    init_local_config

    load_i18n

    [[ $EUID -ne 0 ]] && _error "${I18N_DATA['root']}"

    check_os

    local is_first_run=0
    if [[ ! -f "${SCRIPT_CONFIG_PATH}" ]]; then
        is_first_run=1
    fi

    if [[ "${is_first_run}" -eq 1 || "${FORCE_CHECK_DEPS}" -eq 1 ]]; then
        if ! check_dependencies; then
            install_dependencies
        fi
        if ! check_dependencies; then
            install_dependencies
        fi
    fi

    if [[ ! -d "${SCRIPT_CONFIG_DIR}" ]]; then
        mkdir -p "${SCRIPT_CONFIG_DIR}"
    fi
    init_local_config

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --vision | --xhttp | --fallback)
            QUICK_INSTALL="${1}"
            ;;
        -d)
            shift
            PROJECT_ROOT_OVERRIDE="${1}"
            ;;
        esac
        shift
    done

    local script_path="$(jq -r '.path' "${SCRIPT_CONFIG_PATH}")"
    if [[ -z "${script_path}" && -z "${PROJECT_ROOT_OVERRIDE}" ]]; then
        PROJECT_ROOT="${CUR_DIR}"
        SCRIPT_CONFIG="$(jq --arg path "${PROJECT_ROOT}" '.path = $path' "${SCRIPT_CONFIG_PATH}")"
        echo "${SCRIPT_CONFIG}" >"${SCRIPT_CONFIG_PATH}" && sleep 2
    elif [[ -n "${script_path}" ]]; then
        PROJECT_ROOT="${script_path}"
    elif [[ -n "${PROJECT_ROOT_OVERRIDE}" ]]; then
        PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE}"
        SCRIPT_CONFIG="$(jq --arg path "${PROJECT_ROOT}" '.path = $path' "${SCRIPT_CONFIG_PATH}")"
        echo "${SCRIPT_CONFIG}" >"${SCRIPT_CONFIG_PATH}" && sleep 2
    fi

    I18N_DIR="${PROJECT_ROOT}/i18n"
    CORE_DIR="${PROJECT_ROOT}/core"
    SERVICE_DIR="${PROJECT_ROOT}/service"
    CONFIG_DIR="${PROJECT_ROOT}/config"
    TOOL_DIR="${PROJECT_ROOT}/tool"

    if [[ ! -d "${PROJECT_ROOT}" ]]; then
        _error "Project root not found: ${PROJECT_ROOT}"
    fi

    local lang="$(jq -r '.language' "${SCRIPT_CONFIG_PATH}")"
    if [[ -z "${lang}" && -z "${LANG_PARAM}" ]]; then
        bash "${CORE_DIR}/menu.sh" '--language'
        case $? in
        2) LANG_PARAM="en" ;;
        *) LANG_PARAM="zh" ;;
        esac
        SCRIPT_CONFIG="$(jq --arg language "${LANG_PARAM}" '.language = $language' "${SCRIPT_CONFIG_PATH}")"
        echo "${SCRIPT_CONFIG}" >"${SCRIPT_CONFIG_PATH}" && sleep 2
    elif [[ "${LANG_PARAM}" =~ ^--lang= ]]; then
        SCRIPT_CONFIG="$(jq --arg language "${LANG_PARAM#*=}" '.language = $language' "${SCRIPT_CONFIG_PATH}")"
        echo "${SCRIPT_CONFIG}" >"${SCRIPT_CONFIG_PATH}" && sleep 2
    fi

    bash "${CORE_DIR}/main.sh" "${QUICK_INSTALL}"
}

main "$@"
