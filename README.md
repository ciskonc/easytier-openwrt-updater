# OpenWrt EasyTier Updater

EasyTier 自动更新脚本，适用于 OpenWrt / ImmortalWrt。

通过检测 [luci-app-easytier](https://github.com/EasyTier/luci-app-easytier) 的最新 Release，自动下载并安装对应架构的包。脚本在更新过程中会捕获 `SIGHUP`/`SIGINT`/`SIGPIPE` 信号，确保即使 SSH 因 EasyTier 重启而断开，脚本仍能在后台完成安装。

## 特性

- **信号免疫**：忽略 `SIGHUP`、`SIGINT`、`SIGPIPE`，SSH 断开后脚本继续运行
- **多链路回退**：直连 GitHub 失败后自动切换镜像（ghfast.top、gh-proxy.com、ghproxy.cc）
- **架构自适应**：自动识别设备架构，兼容 opkg（22.03）和 apk（24.10+）包管理器
- **完整性校验**：下载后解压验证，防止代理返回错误内容
- **依赖自检**：自动安装缺失的 curl 和 SSL 证书

## 使用方法

在 OpenWrt 终端执行：

```bash
sh -c "$(curl -sSL https://raw.githubusercontent.com/ciskonc/openwrt-easytier-updater/main/et_update_ha.sh)"
```

如果 curl 不可用，可手动操作：

```bash
wget -O /tmp/update.sh https://raw.githubusercontent.com/ciskonc/openwrt-easytier-updater/main/et_update_ha.sh
sh /tmp/update.sh
```

### 交互说明

- **回车或 Y**：直连优先（10 秒超时），适合海外节点或有代理的环境
- **输入 n**：直接使用镜像加速，跳过直连尝试

## 常见问题

**Q: 为什么检测到的版本号和 EasyTier 官方核心版本号不一致？**
A: 本脚本依赖 `luci-app-easytier` 项目的 Release 记录，只有该项目发布包含新核心的包后，脚本才能获取到更新。

**Q: 更新时 SSH 断开了？**
A: 正常现象。更新过程中 EasyTier 进程会被重启，导致隧道断开。脚本已设置信号免疫，会在后台完成安装并重启服务。等待约 1 分钟后重新连接即可。

**Q: 断线后如何确认更新结果？**
A: 执行 `cat /tmp/et_install.log` 查看安装日志。

**Q: 提示"所有 API 节点均失败"怎么办？**
A: 可能是网络问题导致无法访问 GitHub API 和镜像。请检查网络连接，或手动访问 [Release 页面](https://github.com/EasyTier/luci-app-easytier/releases) 下载对应架构的包。

## 致谢

- [EasyTier](https://github.com/EasyTier/EasyTier) — 虚拟局域网组网核心
- [luci-app-easytier](https://github.com/EasyTier/luci-app-easytier) — OpenWrt LuCI 面板及预编译包
