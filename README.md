# Xray VLESS + Vision + REALITY 一键安装脚本

这个仓库提供一个面向 Linux 服务器的 Xray 一键安装脚本，默认部署 VLESS + XTLS Vision + REALITY。

## 主要变化

- 默认客户端指纹改为 `chrome`。
- 默认 REALITY 伪装地址改为 `aod.itunes.apple.com:443`，SNI 为 `aod.itunes.apple.com`。
- 支持通过参数覆盖 REALITY 目标：`-server-name` 和 `-target`。
- 安装路径恢复为 `/root/xray`，方便按原脚本习惯管理。
- 因为 `/root` 默认不允许普通用户遍历，服务默认以 `root` 用户运行。
- systemd 保留基础加固：`NoNewPrivileges`、`ProtectHome=read-only`、独立临时目录、仅保留绑定低端口能力。
- 下载 Xray 后会在校验文件可用时验证 SHA-256。
- 参数校验更严格：端口、UUID、短 ID、REALITY target、fingerprint 都会先验证。

## 使用方式

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/irasutoya/xray/main/install.sh)
```

本地运行：

```shell
bash install.sh
```

WebSocket 版本：

```shell
bash install-ws.sh
```

## 参数

```text
Usage:
  install.sh [options]

Options:
  -port <1-65535>          监听端口，默认 443
  -uuid <uuid>             VLESS UUID，默认自动生成
  -version <tag|latest>    Xray 版本，例如 v25.4.30，默认 latest
  -server-name <domain>    REALITY SNI/serverName，默认 aod.itunes.apple.com
  -target <host:port>      REALITY target，默认 aod.itunes.apple.com:443
  -fingerprint <name>      uTLS 客户端指纹，默认 chrome
  -short-id <hex>          REALITY shortId，偶数长度十六进制，最长 16 字符，默认随机
  -no-start                只安装并校验配置，不启动服务
  -uninstall               卸载服务和已安装文件
  -help                    显示帮助
```

示例：

```shell
bash install.sh -port 443 -server-name aod.itunes.apple.com -target aod.itunes.apple.com:443
```

WebSocket 版本支持：

```text
  -port <1-65535>          监听端口，默认 80
  -uuid <uuid>             VLESS UUID，默认自动生成
  -version <tag|latest>    Xray 版本，例如 v25.4.30，默认 latest
  -path <path>             WebSocket 路径，默认 /
  -host <domain|ip>        客户端输出中的 WebSocket Host，默认服务器 IP
  -no-start                只安装并校验配置，不启动服务
  -uninstall               卸载服务和已安装文件
```

## 安装路径

- 主目录：`/root/xray`
- 二进制：`/root/xray/bin/xray`
- 配置文件：`/root/xray/config/config.json`
- 运行状态目录：`/root/xray/state`
- systemd 服务：`/etc/systemd/system/xray.service`

## 客户端配置格式

安装完成后脚本会输出 VLESS URL 和 Mihomo / Clash Meta 配置。

VLESS URL 中的核心参数：

```text
security=reality
flow=xtls-rprx-vision
sni=aod.itunes.apple.com
fp=chrome
type=tcp
```

Mihomo / Clash Meta 中的核心参数：

```yaml
network: tcp
servername: aod.itunes.apple.com
client-fingerprint: chrome
reality-opts:
  public-key: <PUBLIC_KEY>
  short-id: <SHORT_ID>
```

## REALITY 目标选择

脚本默认使用 `aod.itunes.apple.com:443` 作为通用默认值。更稳妥的做法是根据服务器网络环境自行选择目标，并用以下条件筛选：

- 支持 TLS 1.3 和 HTTP/2。
- 域名本身不要只做跳转。
- 目标 IP 与服务器网络位置接近时更自然、延迟更低。
- 避免选择容易导致回落流量被滥用的目标。

可以在服务器上用 Xray 检查目标：

```shell
xray tls ping aod.itunes.apple.com
```

## 常用命令

查看服务状态：

```shell
systemctl status xray --no-pager
```

查看日志：

```shell
journalctl -u xray -e --no-pager
```

卸载：

```shell
bash install.sh -uninstall
```

## 说明

请只在你有权管理的服务器上使用，并遵守服务器所在地和使用所在地的法律法规。
