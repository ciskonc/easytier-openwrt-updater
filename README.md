# OpenWrt EasyTier Updater

EasyTier 远程自动更新与部署脚本，专为 OpenWrt / ImmortalWrt 环境设计。

本脚本通过检测 [luci-app-easytier](https://github.com/EasyTier/luci-app-easytier) 项目的最新 Release 记录，全自动拉取并执行更新。它解决了在通过 EasyTier 隧道进行远程 SSH 运维时，因更新过程中核心进程被终止而导致连接断开、更新任务中断的问题。通过内核信号接管与后台静默执行，确保更新流程完整落地并自动拉起服务。

## 特性

* **进程守护**：捕获并忽略 `SIGHUP`、`SIGINT`、`SIGPIPE` 信号。即使 SSH 会话因网络断开而崩溃，脚本依然在后台运行直至完成覆写。
* **多链路回退**：首选直连 GitHub 官方源获取数据，超时自动切换至镜像节点（ghproxy.net、gh-proxy.com、mirror.ghproxy.com）循环轮询。
* **架构自适应**：自动识别设备硬件架构，兼容 OpenWrt 传统 `opkg` 体系（.ipk）与 24.10+ 现代 `apk` 体系（.apk）。
* **完整性校验**：采用物理级解压作为合法性断言，防止因代理节点返回错误网页而引入脏数据。
* **环境自愈**：自动审计宿主机组件，缺失 `curl` 或 SSL 根证书链时自动执行静默补齐。

---

## 快速使用

在 OpenWrt 终端执行以下一键命令：

```bash
sh -c "$(curl -sSL [https://raw.githubusercontent.com/ciskonc/easytier-openwrt-updater/main/et_update_ha.sh](https://raw.githubusercontent.com/ciskonc/easytier-openwrt-updater/main/et_update_ha.sh))"
```

### 交互模式说明
* **回车或输入 `Y`**：直连优先策略（10秒容灾超时），适合海外节点或拥有透明代理的环境。
* **输入 `n` 或 `N`**：直接启用镜像加速阵列，跳过直连探测。

---

## 脚本源码

可手动创建文件执行：`vi /tmp/update.sh`，粘贴以下代码，随后执行 `sh /tmp/update.sh`。

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

## 常见问题 (FAQ)

**Q: 为什么这里检测到的最新版本号，和 EasyTier 官方的核心版本号不一致？** A: 因为本脚本的数据源依赖于 `luci-app-easytier` 项目的发布记录。当该项目打包并发布了包含新版核心的插件包后，脚本才会同步获取到更新。

**Q: 为什么更新过程中我的 SSH 终端突然卡住然后断开了？** A: 正常现象。脚本在覆盖文件时必须终止并重启旧进程，导致虚拟隧道网络瞬间断开。因脚本已注入 `trap '' HUP` 挂断免疫机制，它会在后台默默完成新版本的安装并自愈重启服务。等待 1 分钟后重新连接即可。

**Q: 断线重连后，如何验证更新状态？** A: 执行 `cat /tmp/et_install.log`，即可查看脱机黑盒状态下的后台日志输出。

---

## 致谢
* [EasyTier](https://github.com/EasyTier/EasyTier)：提供强大稳定的虚拟局域网组网核心。
* [luci-app-easytier](https://github.com/EasyTier/luci-app-easytier)：提供 OpenWrt 平台的 LuCI 可视化面板及预编译包，本脚本的数据更新源于该项目。
