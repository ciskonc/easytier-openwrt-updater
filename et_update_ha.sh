#!/bin/sh
# EasyTier 自动更新脚本 (OpenWrt / ImmortalWrt)
# 忽略 SIGHUP/SIGINT/SIGPIPE，防止 SSH 断开导致脚本中断
trap '' HUP INT PIPE

. /etc/openwrt_release
echo "======================================================"
echo "[INFO] 系统架构: ${DISTRIB_ARCH}"

# 0. 选择下载方式
printf "[?] 是否优先直连 GitHub (默认 Y, 超时5秒)? [Y/n]: "
read -r USE_DIRECT < /dev/tty
USE_DIRECT=${USE_DIRECT:-Y}

case "$USE_DIRECT" in
    [nN]*)
        echo "[INFO] 使用镜像加速。"
        DIRECT_MODE=0
        ;;
    *)
        echo "[INFO] 直连优先。"
        DIRECT_MODE=1
        ;;
esac
echo "======================================================"

# 1. 检测包管理器
if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"; TAG="SNAPSHOT"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"; TAG="22.03"
else
    echo "[错误] 未找到 apk 或 opkg。"; exit 1
fi

# 2. 安装 curl（如果没有）
echo "[INFO] 检查依赖..."
if ! command -v curl >/dev/null 2>&1; then
    echo "[INFO] 安装 curl 和证书..."
    if [ "$PKG_MGR" = "apk" ]; then
        apk update >/dev/null 2>&1 && apk add curl ca-certificates >/dev/null 2>&1
    else
        opkg update >/dev/null 2>&1 && opkg install curl ca-bundle ca-certificates >/dev/null 2>&1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "[错误] curl 安装失败，请检查软件源。"; exit 1
    fi
fi

# 3. 从 GitHub API 获取下载地址
API_URL="https://api.github.com/repos/EasyTier/luci-app-easytier/releases/latest"

# GitHub 镜像列表
MIRRORS="https://ghfast.top https://gh-proxy.com https://ghproxy.cc"

# 请求 API
fetch_api() {
    curl -sSL -m 5 "$1" 2>/dev/null
}

# 从 API 响应中提取下载 URL
# sed 提取 browser_download_url 字段，再按架构和标签过滤
extract_download_url() {
    local response="$1"
    local arch="$2"
    local tag="$3"
    echo "$response" | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' \
        | grep "$arch" | grep "$tag" | head -n 1
}

RAW_URL=""

# 直连尝试
if [ "$DIRECT_MODE" -eq 1 ]; then
    echo "[INFO] 请求 GitHub API..."
    RESPONSE=$(fetch_api "$API_URL")
    RAW_URL=$(extract_download_url "$RESPONSE" "$DISTRIB_ARCH" "$TAG")
fi

# 镜像回退
if [ -z "$RAW_URL" ]; then
    [ "$DIRECT_MODE" -eq 1 ] && echo "[INFO] 直连失败，尝试镜像..."
    for MIRROR in $MIRRORS; do
        echo "[INFO] 尝试镜像: $MIRROR"
        RESPONSE=$(fetch_api "${MIRROR}/${API_URL}")
        RAW_URL=$(extract_download_url "$RESPONSE" "$DISTRIB_ARCH" "$TAG")
        [ -n "$RAW_URL" ] && break
    done
fi

if [ -z "$RAW_URL" ]; then
    echo "[错误] 无法获取下载地址。"
    echo "[提示] 请检查网络，或手动访问 https://github.com/EasyTier/luci-app-easytier/releases"
    exit 1
fi

echo "[INFO] 下载地址: $RAW_URL"

# 4. 下载并验证
DOWNLOAD_SUCCESS=0
mkdir -p /tmp/et_pkg

# 按优先级构建下载链接列表
if [ "$DIRECT_MODE" -eq 1 ]; then
    DOWNLOAD_URLS="$RAW_URL"
    for MIRROR in $MIRRORS; do
        DOWNLOAD_URLS="$DOWNLOAD_URLS
${MIRROR}/$RAW_URL"
    done
else
    DOWNLOAD_URLS=""
    for MIRROR in $MIRRORS; do
        DOWNLOAD_URLS="$DOWNLOAD_URLS
${MIRROR}/$RAW_URL"
    done
    DOWNLOAD_URLS="$DOWNLOAD_URLS
$RAW_URL"
fi

# 去重
DOWNLOAD_URLS=$(echo "$DOWNLOAD_URLS" | awk '!seen[$0]++' | grep -v '^$')

for URL in $DOWNLOAD_URLS; do
    echo "[INFO] 下载: $URL"
    rm -rf /tmp/et.zip /tmp/et_pkg/*

    wget -qO /tmp/et.zip -T 60 --no-check-certificate "$URL" 2>/dev/null

    # 验证文件：非空且可解压
    if [ -s "/tmp/et.zip" ] && unzip -q -o /tmp/et.zip -d /tmp/et_pkg >/dev/null 2>&1; then
        DOWNLOAD_SUCCESS=1
        echo "[INFO] 下载成功。"
        break
    else
        echo "[INFO] 下载失败，尝试下一个链接..."
    fi
done

if [ "$DOWNLOAD_SUCCESS" -eq 0 ]; then
    echo "[错误] 所有下载链接均失败。"
    exit 1
fi

echo "======================================================"
echo "[警告] 即将安装，Ctrl+C 已禁用。"
echo "[警告] 通过 EasyTier 连接时 SSH 可能断开，脚本会继续运行。"
echo "======================================================"
sleep 3

# 安装前再次锁定信号
trap '' HUP INT PIPE

# 5. 安装
echo "[INFO] 开始安装..." > /tmp/et_install.log
if [ "$PKG_MGR" = "apk" ]; then
    apk add --allow-untrusted /tmp/et_pkg/*.apk >> /tmp/et_install.log 2>&1
else
    opkg install /tmp/et_pkg/*.ipk >> /tmp/et_install.log 2>&1
fi

# 6. 重启服务
echo "[INFO] 安装完成，重启服务..." >> /tmp/et_install.log
if [ -f "/etc/init.d/easytier" ]; then
    /etc/init.d/easytier reload >> /tmp/et_install.log 2>&1
    /etc/init.d/easytier restart >> /tmp/et_install.log 2>&1
    sleep 3
    if pgrep easytier > /dev/null; then
        echo "[成功] EasyTier 已重启。" >> /tmp/et_install.log
    else
        echo "[警告] 服务启动失败，请手动检查。" >> /tmp/et_install.log
    fi
fi

# 7. 清理临时文件
rm -rf /tmp/et.zip /tmp/et_pkg /tmp/et_update_ha.sh
