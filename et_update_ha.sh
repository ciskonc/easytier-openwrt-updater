#!/bin/sh
# 核心防御：免疫终端挂断与管道破裂信号
trap '' HUP INT PIPE

. /etc/openwrt_release
echo "======================================================"
echo "[INFO] 探测到系统架构: ${DISTRIB_ARCH}"

# 0. 交互式路由决策
printf "[?] 是否优先尝试直连 GitHub (默认优先, 超时10秒)? [Y/n]: "
read -r USE_DIRECT < /dev/tty
USE_DIRECT=${USE_DIRECT:-Y}

case "$USE_DIRECT" in
    [nN]*)
        echo "[INFO] => 用户指令：跳过直连，启用镜像加速阵列。"
        DIRECT_MODE=0
        ;;
    *)
        echo "[INFO] => 用户指令：启用直连优先策略。"
        DIRECT_MODE=1
        ;;
esac
echo "======================================================"

# 1. 包管理器动态适配
if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"; TAG="SNAPSHOT"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"; TAG="22\.03"
else
    echo "[致命错误] 缺失受支持的底层包管理器。"; exit 1
fi

# 2. 核心基建环境自检与自动注入
echo "[INFO] 正在执行宿主机基建依赖审计..."
if ! command -v curl >/dev/null 2>&1; then
    echo "[警告] 缺失核心网络组件 (curl/ca-certs)，正在全自动补齐..."
    if [ "$PKG_MGR" = "apk" ]; then
        apk update >/dev/null 2>&1 && apk add curl ca-certificates >/dev/null 2>&1
    else
        opkg update >/dev/null 2>&1 && opkg install curl ca-bundle ca-certificates >/dev/null 2>&1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "[致命错误] 依赖自愈失败！请检查软件源配置。"; exit 1
    fi
fi

# 3. 动态 API 嗅探 (加入代理节点阵列轮询)
RAW_URL=""
if [ "$DIRECT_MODE" -eq 1 ]; then
    echo "[INFO] 正在向 GitHub 原生 API 发起嗅探..."
    RAW_URL=$(curl -sSL -m 10 "https://api.github.com/repos/EasyTier/luci-app-easytier/releases/latest" 2>/dev/null | tr ',' '\n' | grep "browser_download_url" | grep "$DISTRIB_ARCH" | grep "$TAG" | head -n 1 | cut -d '"' -f 4)
fi

if [ -z "$RAW_URL" ]; then
    [ "$DIRECT_MODE" -eq 1 ] && echo "[警告] 直连探针溃散，触发容灾降级，进入镜像阵列..."
    API_PROXIES="https://ghproxy.net https://gh-proxy.com https://mirror.ghproxy.com"
    for PROXY in $API_PROXIES; do
        RAW_URL=$(curl -sSL -m 10 "${PROXY}/https://api.github.com/repos/EasyTier/luci-app-easytier/releases/latest" 2>/dev/null | tr ',' '\n' | grep "browser_download_url" | grep "$DISTRIB_ARCH" | grep "$TAG" | head -n 1 | cut -d '"' -f 4)
        [ -n "$RAW_URL" ] && break
    done
fi

if [ -z "$RAW_URL" ]; then echo "[致命错误] 全节点 API 嗅探溃散。"; exit 1; fi

# 4. 动态大文件物理链路排布
if [ "$DIRECT_MODE" -eq 1 ]; then
    DOWNLOAD_URLS="$RAW_URL
https://ghproxy.net/$RAW_URL
https://gh-proxy.com/$RAW_URL
https://mirror.ghproxy.com/$RAW_URL"
else
    DOWNLOAD_URLS="https://ghproxy.net/$RAW_URL
https://gh-proxy.com/$RAW_URL
https://mirror.ghproxy.com/$RAW_URL
$RAW_URL"
fi

DOWNLOAD_SUCCESS=0
mkdir -p /tmp/et_pkg

for URL in $DOWNLOAD_URLS; do
    echo "[INFO] 正在建立高速下载链路: $URL"
    rm -rf /tmp/et.zip /tmp/et_pkg/*
    
    wget -qO /tmp/et.zip -T 60 --no-check-certificate "$URL" 2>/dev/null
    
    # 物理级解压断言防投毒
    if [ -s "/tmp/et.zip" ] && unzip -q -o /tmp/et.zip -d /tmp/et_pkg >/dev/null 2>&1; then
        DOWNLOAD_SUCCESS=1
        echo "[INFO] 物理文件解压成功！彻底确认资产合法。"
        break
    else
        echo "[警告] 链路阻塞或遭受投毒，切换下一链路..."
    fi
done

if [ "$DOWNLOAD_SUCCESS" -eq 0 ]; then echo "[致命错误] 物理链路全线溃散！"; exit 1; fi

echo "======================================================"
echo "[高能预警] 即将进入底层覆写阶段！"
echo "[高能预警] 进程免疫锁已被激活。从此刻起，按 Ctrl+C 将无效！"
echo "[高能预警] 若通过 EasyTier 隧道连接，SSH 断裂属于正常现象。"
echo "[高能预警] 路由系统将在后台自动完成覆写并重启隧道，请等待 1 分钟即可。"
echo "======================================================"
sleep 3

# 锁定进程，强行覆写
trap '' HUP INT PIPE

echo "[INFO] 正在向内核发起覆写命令..." > /tmp/et_install.log
if [ "$PKG_MGR" = "apk" ]; then
    apk add --allow-untrusted /tmp/et_pkg/*.apk >> /tmp/et_install.log 2>&1
else
    opkg install /tmp/et_pkg/*.ipk >> /tmp/et_install.log 2>&1
fi

echo "[INFO] 覆写完毕，正在执行自愈挂载..." >> /tmp/et_install.log
if [ -f "/etc/init.d/easytier" ]; then
    /etc/init.d/easytier reload >> /tmp/et_install.log 2>&1
    /etc/init.d/easytier restart >> /tmp/et_install.log 2>&1
    sleep 3
    if pgrep easytier > /dev/null; then
        echo "[成功] EasyTier 守护进程已自愈并驻留后台！" >> /tmp/et_install.log
    else
        echo "[警告] 守护进程唤醒失败，请人工检查。" >> /tmp/et_install.log
    fi
fi

rm -rf /tmp/et.zip /tmp/et_pkg /tmp/et_update_ha.sh
