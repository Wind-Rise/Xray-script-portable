#!/usr/bin/env bash
# =============================================================================
# 脚本名称: nginx.sh
# 功能描述: 用于管理 Nginx/OpenResty 的脚本。
#           支持三种模式:
#           - compile: 从源代码编译安装 Nginx (集成 OpenSSL 和可选 Brotli)
#           - openresty: 使用系统已安装的 OpenResty
#           - system: 使用系统已安装的 Nginx
#           负责管理 Nginx 的 systemd 服务配置。
# 时间: 2025-07-25
# 版本: 1.0.0
# 依赖: bash, curl, wget, git, gcc, make, awk, grep, sed, sort, tr, systemctl, jq,
#       dnf/yum/apt (用于安装编译依赖，仅 compile 模式)
# 配置:
#   - ${TMPFILE_DIR}/: 用于下载和编译的临时工作目录 (仅 compile 模式)
#   - ${NGINX_PATH}/: Nginx 的安装目录 (${PROJECT_ROOT}/nginx)
#   - ${NGINX_LOG_PATH}/: Nginx 的日志目录 (${PROJECT_ROOT}/nginx/logs)
#   - /etc/systemd/system/nginx.service: Nginx systemd 服务文件
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language) 和 URL 配置
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
# 相关链接:
#   - NGINX 官方文档: https://nginx.org/en/linux_packages.html
#   - OpenResty 官方文档: https://openresty.org/
#   - GCC 优化参考: https://github.com/kirin10000/Xray-script
#   - Brotli 模块参考: https://www.nodeseek.com/post-37224-1
#   - ngx_brotli 模块: https://github.com/google/ngx_brotli
# =============================================================================

# set -Eeuxo pipefail

# --- 环境与常量设置 ---
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:/snap/bin
export PATH

# 注册一个退出时执行的清理函数 egress
trap egress EXIT

# 定义颜色代码，用于在终端输出带颜色的信息
readonly RED='\033[31m'    # 红色
readonly GREEN='\033[32m'  # 绿色
readonly YELLOW='\033[33m' # 黄色
readonly NC='\033[0m'      # 无颜色（重置）

# 获取当前脚本的目录、文件名（不含扩展名）和项目根目录的绝对路径
readonly CUR_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)" # 当前脚本所在目录
readonly CUR_FILE="$(basename "$0" | sed 's/\..*//')"         # 当前脚本文件名 (不含扩展名)
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录

# 定义项目中各个重要目录与配置文件的路径
readonly SCRIPT_CONFIG_DIR="${PROJECT_ROOT}/.xray-script"      # 主配置文件目录
readonly I18N_DIR="${PROJECT_ROOT}/i18n"                       # 国际化文件目录
readonly SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_DIR}/config.json" # 脚本主要配置文件路径

# 创建一个唯一的临时目录用于编译工作，并在脚本退出时清理
# 如果创建失败则退出脚本
readonly TMPFILE_DIR="$(mktemp -d -p "${PROJECT_ROOT}" -t nginxtemp.XXXXXXXX 2>/dev/null || mktemp -d -t nginxtemp.XXXXXXXX)" || exit 1

# 定义 Nginx 和其日志的安装/存储路径
readonly NGINX_PATH="${PROJECT_ROOT}/nginx"   # Nginx 安装主目录
readonly NGINX_LOG_PATH="${PROJECT_ROOT}/nginx/logs" # Nginx 日志目录
readonly SYSTEMD_SERVICE_PATH="/etc/systemd/system/nginx.service" # Nginx systemd 服务文件路径（仅在 --service 时创建）

# --- 全局变量声明 ---
declare IS_ENABLE_BROTLI="" # 存储用户是否选择启用 Brotli ('Y' 或 '')
declare ENABLE_SYSTEMD=""   # 存储用户是否选择配置 systemd 服务 ('Y' 或 '')
declare LANG_PARAM=''       # (未在脚本中实际使用，可能是预留)
declare I18N_DATA=''        # 存储从 i18n JSON 文件中读取的全部数据
declare -a cflags=()        # 存储 GCC 编译优化选项

# =============================================================================
# 函数名称: egress
# 功能描述: 在脚本退出时执行的清理操作。
# =============================================================================
function egress() {
    [[ -e "${TMPFILE_DIR}/swap" ]] && swapoff "${TMPFILE_DIR}/swap" 2>/dev/null || true
    rm -rf "${TMPFILE_DIR}"
}

# =============================================================================
# 函数名称: load_i18n
# 功能描述: 加载国际化 (i18n) 数据。
# =============================================================================
function load_i18n() {
    local lang="$(jq -r '.language' "${SCRIPT_CONFIG_PATH}")"

    if [[ "$lang" == "auto" ]]; then
        lang=$(echo "$LANG" | cut -d'_' -f1)
    fi

    local i18n_file="${I18N_DIR}/${lang}.json"

    if [[ ! -f "${i18n_file}" ]]; then
        if [[ "$lang" == "zh" ]]; then
            echo -e "${RED}[错误]${NC} 文件不存在: ${i18n_file}" >&2
        else
            echo -e "${RED}[Error]${NC} File Not Found: ${i18n_file}" >&2
        fi
        exit 1
    fi

    I18N_DATA="$(jq '.' "${i18n_file}")"
}

# =============================================================================
# 函数名称: print_info
# 功能描述: 以绿色打印信息级别的提示消息。
# =============================================================================
function print_info() {
    printf "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')] ${NC}%s\n" "$*" >&2
}

# =============================================================================
# 函数名称: print_warn
# 功能描述: 以黄色打印警告级别的提示消息。
# =============================================================================
function print_warn() {
    printf "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.warn')] ${NC}%s\n" "$*" >&2
}

# =============================================================================
# 函数名称: print_error
# 功能描述: 以红色打印错误级别的提示消息，并退出脚本。
# =============================================================================
function print_error() {
    printf "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')] ${NC}%s\n" "$*" >&2
    exit 1
}

# =============================================================================
# 函数名称: cmd_exists
# 功能描述: 检查指定的命令是否存在于系统中。
# =============================================================================
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

# =============================================================================
# 函数名称: _os
# 功能描述: 检测当前操作系统的发行版名称。
# =============================================================================
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

# =============================================================================
# 函数名称: _os_full
# 功能描述: 获取当前操作系统的完整发行版信息。
# =============================================================================
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

# =============================================================================
# 函数名称: _os_ver
# 功能描述: 获取当前操作系统的主版本号。
# =============================================================================
function _os_ver() {
    local main_ver="$(echo $(_os_full) | grep -oE "[0-9.]+")"
    printf -- "%s" "${main_ver%%.*}"
}

# =============================================================================
# 函数名称: _error_detect
# 功能描述: 执行命令并检查其退出状态，如果失败则打印错误并退出。
# =============================================================================
function _error_detect() {
    local cmd="$1"
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.executing' | sed "s|\${cmd}|${cmd}|")"
    eval "${cmd}"
    if [[ $? -ne 0 ]]; then
        print_error "$(echo "$I18N_DATA" | jq -r '.nginx.compile.fail_exec_cmd' | sed "s|\${cmd}|${cmd}|")"
    fi
}

# =============================================================================
# 函数名称: _version_ge
# 功能描述: 比较两个版本号字符串，判断第一个是否大于等于第二个。
# =============================================================================
function _version_ge() {
    test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "$1"
}

# =============================================================================
# 函数名称: _install
# 功能描述: 根据操作系统类型安装指定的软件包。
# =============================================================================
function _install() {
    local packages_name="$@"
    local installed_packages=""

    case "$(_os)" in
    centos)
        if cmd_exists "dnf"; then
            packages_name="dnf-plugins-core epel-release epel-next-release ${packages_name}"
            installed_packages="$(dnf list installed 2>/dev/null)"
            if [[ -n "$(_os_ver)" && "$(_os_ver)" -eq 9 ]]; then
                if [[ "${packages_name}" =~ geoip\-devel ]] && ! echo "${installed_packages}" | grep -iwq "geoip-devel"; then
                    dnf update -y
                    _error_detect "dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
                    _error_detect "dnf install -y https://dl.fedoraproject.org/pub/epel/epel-next-release-latest-9.noarch.rpm"
                    _error_detect "dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm"
                    _error_detect "dnf config-manager --set-enabled remi-modular"
                    _error_detect "dnf update --refresh"
                    dnf update -y
                    _error_detect "dnf --enablerepo=remi install -y GeoIP-devel"
                fi
            elif [[ -n "$(_os_ver)" && "$(_os_ver)" -eq 8 ]]; then
                if ! dnf module list 2>/dev/null | grep container-tools | grep -iwq "\[x\]"; then
                    _error_detect "dnf module disable -y container-tools"
                fi
            fi
            dnf update -y
            for package_name in ${packages_name}; do
                if ! echo "${installed_packages}" | grep -iwq "${package_name}"; then
                    _error_detect "dnf install -y "${package_name}""
                fi
            done
        else
            packages_name="epel-release yum-utils ${packages_name}"
            installed_packages="$(yum list installed 2>/dev/null)"
            yum update -y
            for package_name in ${packages_name}; do
                if ! echo "${installed_packages}" | grep -iwq "${package_name}"; then
                    _error_detect "yum install -y "${package_name}""
                fi
            done
        fi
        ;;
    ubuntu | debian)
        apt update -y
        installed_packages="$(apt list --installed 2>/dev/null)"
        for package_name in ${packages_name}; do
            if ! echo "${installed_packages}" | grep -iwq "${package_name}"; then
                _error_detect "apt install -y "${package_name}""
            fi
        done
        ;;
    esac
}

# =============================================================================
# 函数名称: check_os
# 功能描述: 检查操作系统是否受支持。
# =============================================================================
function check_os() {
    [[ -z "$(_os)" ]] && print_error "$(echo "$I18N_DATA" | jq -r '.nginx.os.unsupported_os')"

    case "$(_os)" in
    ubuntu)
        [[ -n "$(_os_ver)" && "$(_os_ver)" -lt 20 ]] && print_error "$(echo "$I18N_DATA" | jq -r '.nginx.os.unsupported_ubuntu')"
        ;;
    debian)
        [[ -n "$(_os_ver)" && "$(_os_ver)" -lt 10 ]] && print_error "$(echo "$I18N_DATA" | jq -r '.nginx.os.unsupported_debian')"
        ;;
    centos)
        [[ -n "$(_os_ver)" && "$(_os_ver)" -lt 7 ]] && print_error "$(echo "$I18N_DATA" | jq -r '.nginx.os.unsupported_centos')"
        ;;
    *)
        print_error "$(echo "$I18N_DATA" | jq -r '.nginx.os.unsupported_os')"
        ;;
    esac
}

# =============================================================================
# 函数名称: swap_on
# 功能描述: 创建并启用临时 swap 空间。
# =============================================================================
function swap_on() {
    local mem=${1}
    if [[ ${mem} -ne '0' ]]; then
        if dd if=/dev/zero of="${TMPFILE_DIR}/swap" bs=1M count=${mem} 2>&1; then
            chmod 0600 "${TMPFILE_DIR}/swap"
            mkswap "${TMPFILE_DIR}/swap"
            swapon "${TMPFILE_DIR}/swap"
        fi
    fi
}

# =============================================================================
# 函数名称: backup_files
# 功能描述: 备份指定目录下的所有文件。
# =============================================================================
function backup_files() {
    local backup_dir="$1"
    local current_date="$(date +%F)"
    for file in "${backup_dir}/"*; do
        if [[ -f "$file" ]]; then
            local file_name="$(basename "$file")"
            local backup_file="${backup_dir}/${file_name}_${current_date}"
            mv "$file" "$backup_file"
            echo "$(echo "$I18N_DATA" | jq -r '.nginx.backup_files.backup'): ${file} -> ${backup_file}。"
        fi
    done
}

# =============================================================================
# 函数名称: compile_dependencies
# 功能描述: 安装编译 Nginx 所需的依赖包。
# =============================================================================
function compile_dependencies() {
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.install_deps')"
    _install ca-certificates curl wget gcc make git openssl tzdata socat
    case "$(_os)" in
    centos)
        _install bind-utils gcc-c++ perl-IPC-Cmd perl-Getopt-Long perl-Data-Dumper perl-Time-Piece
        _install pcre2-devel zlib-devel libxml2-devel libxslt-devel gd-devel geoip-devel perl-ExtUtils-Embed gperftools-devel perl-devel brotli-devel
        if ! perl -e "use FindBin" &>/dev/null; then
            _install perl-FindBin
        fi
        ;;
    debian | ubuntu)
        _install dnsutils g++ perl-base perl
        _install libpcre2-dev zlib1g-dev libxml2-dev libxslt1-dev libgd-dev libgeoip-dev libgoogle-perftools-dev libperl-dev libbrotli-dev
        ;;
    esac
}

# =============================================================================
# 函数名称: gen_cflags
# 功能描述: 生成优化的 C 编译器标志 (CFLAGS)。
# =============================================================================
function gen_cflags() {
    cflags=('-g0' '-O3')
    if gcc -v --help 2>&1 | grep -qw "\\-fstack\\-reuse"; then
        cflags+=('-fstack-reuse=all')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fdwarf2\\-cfi\\-asm"; then
        cflags+=('-fdwarf2-cfi-asm')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fplt"; then
        cflags+=('-fplt')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-ftrapv"; then
        cflags+=('-fno-trapv')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fexceptions"; then
        cflags+=('-fno-exceptions')
    elif gcc -v --help 2>&1 | grep -qw "\\-fhandle\\-exceptions"; then
        cflags+=('-fno-handle-exceptions')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-funwind\\-tables"; then
        cflags+=('-fno-unwind-tables')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fasynchronous\\-unwind\\-tables"; then
        cflags+=('-fno-asynchronous-unwind-tables')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fstack\\-check"; then
        cflags+=('-fno-stack-check')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fstack\\-clash\\-protection"; then
        cflags+=('-fno-stack-clash-protection')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fstack\\-protector"; then
        cflags+=('-fno-stack-protector')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fcf\\-protection="; then
        cflags+=('-fcf-protection=none')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fsplit\\-stack"; then
        cflags+=('-fno-split-stack')
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-fsanitize"; then
        >temp.c
        if gcc -E -fno-sanitize=all temp.c >/dev/null 2>&1; then
            cflags+=('-fno-sanitize=all')
        fi
        rm temp.c
    fi
    if gcc -v --help 2>&1 | grep -qw "\\-finstrument\\-functions"; then
        cflags+=('-fno-instrument-functions')
    fi
}

# =============================================================================
# 函数名称: source_compile
# 功能描述: 下载源码并编译 Nginx。
# =============================================================================
function source_compile() {
    cd "${TMPFILE_DIR}"
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.fetch_versions')"
    
    # 从配置文件读取 URL
    local nginx_tags_url="$(jq -r '.urls.nginx_tags' "${SCRIPT_CONFIG_PATH}")"
    local openssl_tags_url="$(jq -r '.urls.openssl_tags' "${SCRIPT_CONFIG_PATH}")"
    local nginx_source_url="$(jq -r '.urls.nginx_source' "${SCRIPT_CONFIG_PATH}")"
    local openssl_source_url="$(jq -r '.urls.openssl_source' "${SCRIPT_CONFIG_PATH}")"
    local ngx_brotli_url="$(jq -r '.urls.ngx_brotli' "${SCRIPT_CONFIG_PATH}")"
    
    # 从 GitHub API 获取最新的 Nginx release 标签名
    local nginx_version="$(wget -qO- --no-check-certificate "${nginx_tags_url}" | grep 'name' | cut -d\" -f4 | grep 'release' | head -1 | sed 's/release/nginx/')"
    # 获取最新的 OpenSSL 标签名
    local openssl_version="openssl-$(wget -qO- --no-check-certificate "${openssl_tags_url}" | grep 'name' | cut -d\" -f4 | grep -Eoi '^openssl-([0-9]\.?){3}$' | head -1)"

    # 生成编译器优化标志
    gen_cflags

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.download_nginx')"
    # 替换 URL 中的版本占位符
    local nginx_download_url="${nginx_source_url/\{version\}/${nginx_version}}"
    _error_detect "curl -fsSL -o ${nginx_version}.tar.gz ${nginx_download_url}"
    tar -zxf "${nginx_version}.tar.gz"

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.download_openssl')"
    local openssl_download_url="${openssl_source_url/\{version\}/${openssl_version#*-}}"
    _error_detect "curl -fsSL -o ${openssl_version}.tar.gz ${openssl_download_url}"
    tar -zxf "${openssl_version}.tar.gz"

    # 如果启用了 Brotli，则下载并初始化 ngx_brotli 模块
    if [[ "${is_enable_brotli}" =~ ^[Yy]$ ]]; then
        print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.fetch_brotli')"
        _error_detect "git clone ${ngx_brotli_url} && cd ngx_brotli && git submodule update --init"
        cd "${TMPFILE_DIR}"
    fi

    cd "${nginx_version}"

    sed -i "s/OPTIMIZE[ \\t]*=>[ \\t]*'-O'/OPTIMIZE          => '-O3'/g" src/http/modules/perl/Makefile.PL
    sed -i 's/NGX_PERL_CFLAGS="$CFLAGS `$NGX_PERL -MExtUtils::Embed -e ccopts`"/NGX_PERL_CFLAGS="`$NGX_PERL -MExtUtils::Embed -e ccopts` $CFLAGS"/g' auto/lib/perl/conf
    sed -i 's/NGX_PM_CFLAGS=`$NGX_PERL -MExtUtils::Embed -e ccopts`/NGX_PM_CFLAGS="`$NGX_PERL -MExtUtils::Embed -e ccopts` $CFLAGS"/g' auto/lib/perl/conf

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.configure')"
    if [[ "${is_enable_brotli}" =~ ^[Yy]$ ]]; then
        ./configure --prefix="${NGINX_PATH}" --user=root --group=root --with-threads --with-file-aio --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-http_realip_module --with-http_addition_module --with-http_xslt_module=dynamic --with-http_image_filter_module=dynamic --with-http_geoip_module=dynamic --with-http_sub_module --with-http_dav_module --with-http_flv_module --with-http_mp4_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_auth_request_module --with-http_random_index_module --with-http_secure_link_module --with-http_degradation_module --with-http_slice_module --with-http_stub_status_module --with-http_perl_module=dynamic --with-mail=dynamic --with-mail_ssl_module --with-stream --with-stream_ssl_module --with-stream_realip_module --with-stream_geoip_module=dynamic --with-stream_ssl_preread_module --with-google_perftools_module --add-module="../ngx_brotli" --with-compat --with-cc-opt="${cflags[*]}" --with-openssl="../${openssl_version}" --with-openssl-opt="${cflags[*]}"
    else
        ./configure --prefix="${NGINX_PATH}" --user=root --group=root --with-threads --with-file-aio --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-http_realip_module --with-http_addition_module --with-http_xslt_module=dynamic --with-http_image_filter_module=dynamic --with-http_geoip_module=dynamic --with-http_sub_module --with-http_dav_module --with-http_flv_module --with-http_mp4_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_auth_request_module --with-http_random_index_module --with-http_secure_link_module --with-http_degradation_module --with-http_slice_module --with-http_stub_status_module --with-http_perl_module=dynamic --with-mail=dynamic --with-mail_ssl_module --with-stream --with-stream_ssl_module --with-stream_realip_module --with-stream_geoip_module=dynamic --with-stream_ssl_preread_module --with-google_perftools_module --with-compat --with-cc-opt="${cflags[*]}" --with-openssl="../${openssl_version}" --with-openssl-opt="${cflags[*]}"
    fi

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.swap')"
    swap_on 512

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.start_compile')"
    _error_detect "make -j$(nproc)"
}

# =============================================================================
# 函数名称: source_install
# 功能描述: 编译并安装 Nginx。
# =============================================================================
function source_install() {
    source_compile
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.install.start_install')"
    make install
    mkdir -p "${NGINX_LOG_PATH}"
    mkdir -p "${PROJECT_ROOT}/nginx/bin"
    mkdir -p "${PROJECT_ROOT}/nginx/run"
    ln -sf "${NGINX_PATH}/sbin/nginx" "${PROJECT_ROOT}/nginx/bin/nginx"
}

# =============================================================================
# 函数名称: source_update
# 功能描述: 检查并更新 Nginx (如果需要)。
# =============================================================================
function source_update() {
    # 从配置文件读取 URL
    local nginx_tags_url="$(jq -r '.urls.nginx_tags' "${SCRIPT_CONFIG_PATH}")"
    local openssl_tags_url="$(jq -r '.urls.openssl_tags' "${SCRIPT_CONFIG_PATH}")"
    
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.update.fetch_versions')"
    local latest_nginx_version="$(wget -qO- --no-check-certificate "${nginx_tags_url}" | grep 'name' | cut -d\" -f4 | grep 'release' | head -1 | sed 's/release/nginx/')"
    local latest_openssl_version="$(wget -qO- --no-check-certificate "${openssl_tags_url}" | grep 'name' | cut -d\" -f4 | grep -Eoi '^openssl-([0-9]\.?){3}$' | head -1)"

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.update.read_current_versions')"
    local current_version_nginx="$(nginx -V 2>&1 | grep "^nginx version:.*" | cut -d / -f 2)"
    local current_version_openssl="$(nginx -V 2>&1 | grep "^built with OpenSSL" | awk '{print $4}')"

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.update.check_update')"
    if _version_ge "${latest_nginx_version#*-}" "${current_version_nginx}" || _version_ge "${latest_openssl_version#*-}" "${current_version_openssl}"; then
        source_compile
        print_info "$(echo "$I18N_DATA" | jq -r '.nginx.update.start_update')"
        mv "${NGINX_PATH}/sbin/nginx" "${NGINX_PATH}/sbin/nginx_$(date +%F)"
        backup_files "${NGINX_PATH}/modules"
        cp objs/nginx "${NGINX_PATH}/sbin/"
        cp objs/*.so "${NGINX_PATH}/modules/"
        ln -sf "${NGINX_PATH}/sbin/nginx" "${PROJECT_ROOT}/nginx/bin/nginx"

        if systemctl is-active --quiet nginx; then
            print_info "$(echo "$I18N_DATA" | jq -r '.nginx.update.smooth_upgrade')"
            kill -USR2 $(cat "${PROJECT_ROOT}/nginx/run/nginx.pid")
            if [[ -e "${PROJECT_ROOT}/nginx/run/nginx.pid.oldbin" ]]; then
                kill -WINCH $(cat "${PROJECT_ROOT}/nginx/run/nginx.pid.oldbin")
                kill -HUP $(cat "${PROJECT_ROOT}/nginx/run/nginx.pid.oldbin")
                kill -QUIT $(cat "${PROJECT_ROOT}/nginx/run/nginx.pid.oldbin")
            else
                print_info "$(echo "$I18N_DATA" | jq -r '.nginx.update.no_old_process')"
            fi
        fi
        return 0
    fi
    return 1
}

# =============================================================================
# 函数名称: purge_nginx
# 功能描述: 完全卸载 Nginx。
# =============================================================================
function purge_nginx() {
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.purge.start_purge')"
    if [[ -f "${SYSTEMD_SERVICE_PATH}" ]]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop nginx || true
        fi
        rm -rf "${SYSTEMD_SERVICE_PATH}"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload || true
        fi
    else
        print_warn "$(echo "$I18N_DATA" | jq -r '.nginx.purge.no_service')"
    fi
    rm -rf "${NGINX_PATH}"
    rm -rf "${PROJECT_ROOT}/nginx/bin/nginx"
    rm -rf "${NGINX_LOG_PATH}"
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.purge.purged')"
}

# =============================================================================
# 函数名称: systemctl_config_nginx
# 功能描述: 配置 Nginx 的 systemd 服务文件。
# =============================================================================
function systemctl_config_nginx() {
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.service.configure')"
    cat >/etc/systemd/system/nginx.service <<EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=${PROJECT_ROOT}/nginx/run/nginx.pid
ExecStartPre=/bin/rm -rf /dev/shm/nginx
ExecStartPre=/bin/mkdir /dev/shm/nginx
ExecStartPre=/bin/chmod 711 /dev/shm/nginx
ExecStartPre=/bin/mkdir /dev/shm/nginx/tcmalloc
ExecStartPre=/bin/chmod 0777 /dev/shm/nginx/tcmalloc
ExecStartPre=${PROJECT_ROOT}/nginx/bin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=${PROJECT_ROOT}/nginx/bin/nginx -g 'daemon on; master_process on;'
ExecReload=${PROJECT_ROOT}/nginx/bin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=/bin/kill -s QUIT \$MAINPID
ExecStopPost=/bin/rm -rf /dev/shm/nginx
TimeoutStopSec=5
KillMode=mixed
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        print_info "$(echo "$I18N_DATA" | jq -r '.nginx.service.complete')"
    else
        print_warn "$(echo "$I18N_DATA" | jq -r '.nginx.service.no_systemctl')"
    fi
}

# =============================================================================
# 函数名称: detect_existing_nginx
# 功能描述: 检测系统中已安装的 nginx/openresty。
# 返回值: 0-检测到 1-未检测到
# =============================================================================
function detect_existing_nginx() {
    local nginx_mode="$(jq -r '.nginx.mode // "compile"' "${SCRIPT_CONFIG_PATH}")"
    
    case "${nginx_mode}" in
    openresty)
        # 检测 OpenResty
        if command -v openresty >/dev/null 2>&1; then
            local openresty_bin="$(command -v openresty)"
            local openresty_version="$(openresty -V 2>&1 | grep "^nginx version:" | cut -d/ -f2)"
            print_info "Detected OpenResty: ${openresty_bin} (version: ${openresty_version})"
            
            # 更新配置文件
            local updated_config="$(jq --arg binary "${openresty_bin}" --arg version "${openresty_version}" \
                '.nginx.binary = $binary | .nginx.version = $version | .nginx.service_name = "openresty"' \
                "${SCRIPT_CONFIG_PATH}")"
            echo "${updated_config}" > "${SCRIPT_CONFIG_PATH}"
            return 0
        else
            print_error "OpenResty mode selected but openresty binary not found in PATH"
        fi
        ;;
    system)
        # 检测系统 Nginx
        if command -v nginx >/dev/null 2>&1; then
            local nginx_bin="$(command -v nginx)"
            local nginx_version="$(nginx -V 2>&1 | grep "^nginx version:" | cut -d/ -f2)"
            print_info "Detected system Nginx: ${nginx_bin} (version: ${nginx_version})"
            
            # 更新配置文件
            local updated_config="$(jq --arg binary "${nginx_bin}" --arg version "${nginx_version}" \
                '.nginx.binary = $binary | .nginx.version = $version | .nginx.service_name = "nginx"' \
                "${SCRIPT_CONFIG_PATH}")"
            echo "${updated_config}" > "${SCRIPT_CONFIG_PATH}"
            return 0
        else
            print_error "System nginx mode selected but nginx binary not found in PATH"
        fi
        ;;
    *)
        return 1
        ;;
    esac
}

# =============================================================================
# 函数名称: show_help
# 功能描述: 显示脚本使用帮助信息。
# =============================================================================
function show_help() {
    local usage="$(echo "$I18N_DATA" | jq -r '.nginx.help.usage' | sed "s|\${script_name}|$0|")"
    local options_title="$(echo "$I18N_DATA" | jq -r '.nginx.help.options_title')"
    local opt_install="$(echo "$I18N_DATA" | jq -r '.nginx.help.opt_install')"
    local opt_update="$(echo "$I18N_DATA" | jq -r '.nginx.help.opt_update')"
    local opt_brotli="$(echo "$I18N_DATA" | jq -r '.nginx.help.opt_brotli')"
    local opt_service="$(echo "$I18N_DATA" | jq -r '.nginx.help.opt_service')"
    local opt_purge="$(echo "$I18N_DATA" | jq -r '.nginx.help.opt_purge')"
    local opt_help="$(echo "$I18N_DATA" | jq -r '.nginx.help.opt_help')"

    cat <<EOF
${usage}
${options_title}:
  --install    ${opt_install}
  --update     ${opt_update}
  --brotli     ${opt_brotli}
  --service    ${opt_service}
  --purge      ${opt_purge}
  --help       ${opt_help}
EOF
    exit 0
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
# =============================================================================
function main() {
    load_i18n
    check_os

    local action=''

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --install | --update | --purge)
            action="${1#--}"
            ;;
        --brotli)
            IS_ENABLE_BROTLI='Y'
            ;;
        --service)
            ENABLE_SYSTEMD='Y'
            ;;
        --help)
            show_help
            ;;
        *)
            print_error "$(echo "$I18N_DATA" | jq -r '.nginx.main.invalid_option' | sed "s|\${option}|$1|")"
            ;;
        esac
        shift
    done

    case "${action}" in
    install)
        # 检查是否使用 openresty/system 模式
        local nginx_mode="$(jq -r '.nginx.mode // "compile"' "${SCRIPT_CONFIG_PATH}")"
        if [[ "${nginx_mode}" == "openresty" || "${nginx_mode}" == "system" ]]; then
            detect_existing_nginx
            if [[ "${ENABLE_SYSTEMD}" == 'Y' ]]; then
                systemctl_config_nginx
            else
                print_info "$(echo "$I18N_DATA" | jq -r '.nginx.service.skip')"
            fi
        else
            compile_dependencies
            source_install
            if [[ "${ENABLE_SYSTEMD}" == 'Y' ]]; then
                systemctl_config_nginx
            else
                print_info "$(echo "$I18N_DATA" | jq -r '.nginx.service.skip')"
            fi
        fi
        ;;
    update)
        local nginx_mode="$(jq -r '.nginx.mode // "compile"' "${SCRIPT_CONFIG_PATH}")"
        if [[ "${nginx_mode}" == "openresty" || "${nginx_mode}" == "system" ]]; then
            print_info "Update not supported for ${nginx_mode} mode. Please update ${nginx_mode} through your system package manager."
        else
            compile_dependencies
            source_update
        fi
        ;;
    purge)
        purge_nginx
        ;;
    esac
}

main "$@"
