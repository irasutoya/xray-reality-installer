# Xray 代理服务一键安装脚本

在 Linux 服务器上自动安装和配置 Xray，支持两种模式：

- **REALITY 模式**：`-mode reality`，VLESS + Vision + REALITY，默认端口 `443`
- **WebSocket 模式**：`-mode ws`，VLESS + WebSocket，默认端口 `80`

## 功能

- 自动检测系统架构并下载对应版本的 Xray
- 自动生成 UUID；REALITY 模式额外生成密钥对和 short ID
- 自动创建 Xray 配置文件和 systemd 服务
- 安装完成后输出 VLESS URL 与 Mihomo 配置
- 支持卸载已安装的 Xray 服务和相关文件

## 系统要求

- Debian/Ubuntu 或 CentOS/RHEL/Fedora 系 Linux 系统
- 需要使用 `root` 用户运行
- 支持架构：`x86_64`、`aarch64`、`armv7l`、`armv6l`、`i386/i686`、`mips64le`、`mipsle`

## 使用方法

REALITY 模式（默认）：

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/irasutoya/xray/main/install.sh)
```

WebSocket 模式：

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/irasutoya/xray/main/install.sh) -mode ws
```

也支持传统入口：

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/irasutoya/xray/main/install-ws.sh)
```

## 命令选项

```shell
用法: install.sh [选项]

选项:
  -mode        安装模式: reality (默认) 或 ws
  -port        监听端口，REALITY 默认 443，WebSocket 默认 80
  -uuid        设置 VLESS UUID，默认随机生成
  -domain      伪装域名（仅 REALITY 模式，默认 gateway.icloud.com）
  -uninstall   卸载 Xray 服务及所有相关文件
  -help        显示帮助信息
```

示例：

```shell
bash install.sh -mode ws -port 8080
bash install.sh -mode reality -port 8443 -domain cloudflare.com
bash install.sh -port 8080 -uuid 00000000-0000-4000-8000-000000000000
bash install.sh -uninstall
```

## 安装路径

- 主目录：`/root/xray`
- 可执行文件：`/root/xray/bin/xray`
- 配置文件：`/root/xray/config/config.json`
- systemd 服务：`/etc/systemd/system/xray.service`

## 故障排除

- 如果服务启动失败，使用 `journalctl -u xray` 查看日志
- 确认防火墙和云厂商安全组已放行对应端口
- 如需重新配置，可以先执行 `-uninstall` 后重新安装

## 免责声明

本项目仅供学习和技术研究使用。使用者必须遵守服务器所在地、所在国家和用户所在地的法律法规。因不当使用产生的任何后果由使用者自行承担。
