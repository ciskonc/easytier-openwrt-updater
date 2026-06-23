#!/bin/sh
# EasyTier 远程自动更新脚本 (OpenWrt / ImmortalWrt)
# 信号免疫：防止 SSH 断开导致更新中断
trap '' HUP INT PIPE

. /etc/openwrt_release
echo "======================================================"
echo "[INFO] 系统架构: ${DISTRIB_ARCH}"

# 0. 交互式路由决策
printf "[?] 是否优先尝试直连 GitHub (默认优先, 超时10秒)? [Y/n]: "
read -r USE_DIRECT < /dev/tty
USE_DIRECT=${USE_DIRECT:-Y}

case "$USE_DIRECT" in
    [nN]*)
        echo "[INFO] 跳过直连，启用镜像加速。"
        DIRECT_MODE=0
        ;;
    *)
        echo "[INFO] 启用直连优先策略。"
        DIRECT_MODE=1
        ;;
esac
echo "======================================================"

# 1. 包管理器动态适配
if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"; TAG="SNAPSHOT"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"; TAG="22.03"
else
    echo "[错误] 未找到受支持的包管理器 (apk/opkg)。"; exit 1
fi

# 2. 环境自检与依赖补齐
echo "[INFO] 检查依赖..."
if ! command -v curl >/dev/null 2>&1; then
    echo "[INFO] 安装 curl 和证书..."
    if [ "$PKG_MGR" = "apk" ]; then
        apk update >/dev/null 2>&1 && apk add curl ca-certificates >/dev/null 2>&1
    else
        opkg update >/dev/null 2>&1 && opkg install curl ca-bundle ca-certificates >/dev/null 2>&1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "[错误] 依赖安装失败，请检查软件源。"; exit 1
    fi
fi

# 3. GitHub API 嗅探
API_URL="https://api.github.com/repos/EasyTier/luci-app-easytier/releases/latest"

# 镜像列表（可按需增删）
MIRRORS="https://ghfast.top https://gh-proxy.com https://ghproxy.cc"

fetch_api() {
    local url="$1"
    curl -sSL -m 15 "$url" 2>/dev/null
}

# 从 API 响应中提取匹配架构和标签的下载 URL
# 使用 sed 提取 browser_download_url 字段值，比 tr+grep 更可靠
extract_download_url() {
    local response="$1"
    local arch="$2"
    local tag="$3"

    echo "$response" | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' \
        | grep "$arch" | grep "$tag" | head -n 1
}

RAW_URL=""

if [ "$DIRECT_MODE" -eq 1 ]; then
    echo "[INFO] 尝试直连 GitHub API..."
    RESPONSE=$(fetch_api "$API_URL")
    RAW_URL=$(extract_download_url "$RESPONSE" "$DISTRIB_ARCH" "$TAG")
fi

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
    echo "[错误] 无法获取下载地址，所有 API 节点均失败。"
    echo "[提示] 请检查网络连接，或手动访问 https://github.com/EasyTier/luci-app-easytier/releases 下载。"
    exit 1
fi

echo "[INFO] 获取到下载地址: $RAW_URL"

# 4. 下载文件
DOWNLOAD_SUCCESS=0
mkdir -p /tmp/et_pkg

# 构建下载链接列表（按优先级排列，去重）
if [ "$DIRECT_MODE" -eq 1 ]; then
    # 直连优先：原始链接 → 镜像链接
    DOWNLOAD_URLS="$RAW_URL"
    for MIRROR in $MIRRORS; do
        DOWNLOAD_URLS="$DOWNLOAD_URLS
${MIRROR}/$RAW_URL"
    done
else
    # 镜像优先：镜像链接 → 原始链接
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

    # 验证：文件非空且能解压
    if [ -s "/tmp/et.zip" ] && unzip -q -o /tmp/et.zip -d /tmp/et_pkg >/dev/null 2>&1; then
        DOWNLOAD_SUCCESS=1
        echo "[INFO] 下载并验证成功。"
        break
    else
        echo "[INFO] 下载失败或文件损坏，尝试下一个链接..."
    fi
done

if [ "$DOWNLOAD_SUCCESS" -eq 0 ]; then
    echo "[错误] 所有下载链接均失败。"
    exit 1
fi

echo "======================================================"
echo "[警告] 即将进入安装阶段！"
echo "[警告] 进程免疫已激活，Ctrl+C 无效。"
echo "[警告] 若通过 EasyTier 隧道连接，SSH 断开属正常现象。"
echo "[警告] 脚本将在后台完成安装并重启服务，请等待约 1 分钟。"
echo "======================================================"
sleep 3

# 再次锁定信号
trap '' HUP INT PIPE

echo "[INFO] 开始安装..." > /tmp/et_install.log
if [ "$PKG_MGR" = "apk" ]; then
    apk add --allow-untrusted /tmp/et_pkg/*.apk >> /tmp/et_install.log 2>&1
else
    opkg install /tmp/et_pkg/*.ipk >> /tmp/et_install.log 2>&1
fi

echo "[INFO] 安装完成，重启服务..." >> /tmp/et_install.log
if [ -f "/etc/init.d/easytier" ]; then
    /etc/init.d/easytier reload >> /tmp/et_install.log 2>&1
    /etc/init.d/easytier restart >> /tmp/et_install.log 2>&1
    sleep 3
    if pgrep easytier > /dev/null; then
        echo "[成功] EasyTier 服务已重启。" >> /tmp/et_install.log
    else
        echo "[警告] 服务启动失败，请手动检查。" >> /tmp/et_install.log
    fi
fi

rm -rf /tmp/et.zip /tmp/et_pkg /tmp/et_update_ha.sh
