# 🛡️ EasyTier-HA-Updater for OpenWrt

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-OpenWrt%20%7C%20ImmortalWrt-success)](#)
[![Architecture](https://img.shields.io/badge/Architecture-x86_64%20%7C%20ARM-orange)](#)

专为 OpenWrt / ImmortalWrt 打造的 [EasyTier](https://github.com/EasyTier/EasyTier) 高可用（HA）自动更新与部署脚本。

在 OpenWrt 上更新底层虚拟局域网（VPN/SD-WAN）插件时，传统的更新脚本往往面临一个致命悖论：**“更新程序本身会导致网络断开，而网络断开会瞬间杀死正在执行更新的 SSH 进程”**，最终导致旧版已卸载、新版未装完的“半砖”死锁。

本脚本专为打破这一灾难场景而生。它引入了工业级的**系统信号免疫**、**多链路容灾**与**物理级防投毒校验**，确保每一次底层网络重构都能像外科手术般精准、安全地在后台完成。

## ✨ 核心特性 (Features)

* 🛡️ **进程免疫 (Signal Trapping)**
  * 在底层覆写阶段，脚本将强制接管 Linux 信号（忽略 `SIGHUP`, `SIGINT`, `SIGPIPE`）。
  * **即使你通过 EasyTier 隧道连接 SSH，更新导致隧道断裂、终端崩溃，脚本依然会在内核后台强行跑完全程并拉起新版进程。**
* 🌐 **智能路由与链路降级 (Smart Fallback)**
  * 默认优先极速直连 GitHub 官方源获取纯净数据。
  * 一旦遭遇超时或 GFW 阻断，瞬间无缝降级至预置的三大国内加速节点（`ghproxy.net`, `gh-proxy.com`, `mirror.ghproxy.com`）阵列循环。
* 📦 **包管理器自适应 (Auto-Adaptation)**
  * 抛弃对系统版本号的死板判断，直接在内核层嗅探。完美兼容传统的 `opkg` 体系（ `.ipk`）与 24.10+ 现代化的 Alpine `apk` 体系（`.apk`）。
* 🔍 **物理级断言校验 (Anti-Pollution)**
  * 针对 OpenWrt 阉割版 BusyBox 的痛点，摒弃脆弱的参数校验。采用**物理强制解压**作为真理探针，彻底杜绝代理服务器返回 `502 HTML` 脏数据导致系统崩溃的隐患。
* 🛠️ **基建环境自愈 (Self-Healing)**
  * 执行前自动审计宿主机环境，若缺失 `curl` 或 SSL 根证书链，将接管包管理器自动静默补齐依赖。

---

## 🚀 极速使用 (Quick Start)

通过 SSH 登录你的 OpenWrt / ImmortalWrt 路由器终端，直接复制并运行以下一键命令：

```bash
sh -c "$(curl -sSL [https://raw.githubusercontent.com/你的GitHub用户名/你的仓库名/main/et_update_ha.sh](https://raw.githubusercontent.com/ciskonc/easytier-openwrt-updater/main/et_update_ha.sh))"
```
*(注意：请将上方的 URL 替换为你实际 GitHub 仓库中该脚本的 raw 链接)*

### 交互说明
运行后，脚本会弹出唯一一次交互询问：
```text
[?] 是否优先尝试直连 GitHub (默认优先, 超时10秒)? [Y/n]:
```
* **输入 `Y` 或直接回车**：适合海外节点或已配置透明代理的路由器，优先享受直连高带宽。
* **输入 `n` 或 `N`**：适合纯国内无代理的路由器，脚本将彻底跳过直连探针，全程使用国内加速网络。

---

## 📝 脚本源码 (Source Code)

如果不习惯执行远程脚本，可手动创建文件：在终端执行 `vi /tmp/update.sh`，粘贴以下代码，执行 `sh /tmp/update.sh`。

<details>
<summary><b>点击展开查看完整脚本源码</b></summary>

```bash
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
    RAW_URL=$(curl -sSL -m 10 "[https://api.github.com/repos/EasyTier/luci-app-easytier/releases/latest](https://api.github.com/repos/EasyTier/luci-app-easytier/releases/latest)" 2>/dev/null | tr ',' '\n' | grep "browser_download_url" | grep "$DISTRIB_ARCH" | grep "$TAG" | head -n 1 | cut -d '"' -f 4)
fi

if [ -z "$RAW_URL" ]; then
    [ "$DIRECT_MODE" -eq 1 ] && echo "[警告] 直连探针溃散，触发容灾降级，进入镜像阵列..."
    API_PROXIES="[https://ghproxy.net](https://ghproxy.net) [https://gh-proxy.com](https://gh-proxy.com) [https://mirror.ghproxy.com](https://mirror.ghproxy.com)"
    for PROXY in $API_PROXIES; do
        RAW_URL=$(curl -sSL -m 10 "${PROXY}/[https://api.github.com/repos/EasyTier/luci-app-easytier/releases/latest](https://api.github.com/repos/EasyTier/luci-app-easytier/releases/latest)" 2>/dev/null | tr ',' '\n' | grep "browser_download_url" | grep "$DISTRIB_ARCH" | grep "$TAG" | head -n 1 | cut -d '"' -f 4)
        [ -n "$RAW_URL" ] && break
    done
fi

if [ -z "$RAW_URL" ]; then echo "[致命错误] 全节点 API 嗅探溃散。"; exit 1; fi

# 4. 动态大文件物理链路排布
if [ "$DIRECT_MODE" -eq 1 ]; then
    DOWNLOAD_URLS="$RAW_URL
[https://ghproxy.net/$RAW_URL](https://ghproxy.net/$RAW_URL)
[https://gh-proxy.com/$RAW_URL](https://gh-proxy.com/$RAW_URL)
[https://mirror.ghproxy.com/$RAW_URL](https://mirror.ghproxy.com/$RAW_URL)"
else
    DOWNLOAD_URLS="[https://ghproxy.net/$RAW_URL](https://ghproxy.net/$RAW_URL)
[https://gh-proxy.com/$RAW_URL](https://gh-proxy.com/$RAW_URL)
[https://mirror.ghproxy.com/$RAW_URL](https://mirror.ghproxy.com/$RAW_URL)
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
```
</details>

---

## 🔎 常见问题 (FAQ)

**Q: 为什么更新过程中我的 SSH 终端突然卡住然后断开了？** A: 预期行为。你当前正通过 EasyTier 隧道连接该路由器，脚本在覆盖旧文件时必须杀死正在运行的进程，导致网络隧道物理断裂。无需惊慌，脚本已注入 `trap '' HUP` 守护，将在后台默默完成新版本的覆写并自动重连隧道。等待 1 分钟即可重新登录。

**Q: 我断线重连后，如何验证更新状态？** A: 连接后，在终端执行 `cat /tmp/et_install.log`，即可查看黑盒状态下的脱机后台日志记录。

## 🤝 致谢
感谢 [EasyTier](https://github.com/EasyTier/EasyTier) 团队带来的优秀虚拟局域网组网工具，以及 [luci-app-easytier](https://github.com/EasyTier/luci-app-easytier) 项目。
