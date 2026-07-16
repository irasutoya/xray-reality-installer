# Xray REALITY 一键安装脚本

在使用 systemd 的 Linux 服务器上安装和管理 VLESS + Vision + REALITY。

## 主要特性

- 交互菜单和非交互命令行安装
- 自动识别架构、安装缺少的依赖并获取 Xray 最新稳定版
- 下载官方 `.dgst` 文件并执行 SHA-256 完整性校验
- 写入前使用 `xray run -test` 验证配置
- 覆盖安装失败时自动恢复旧二进制、配置和服务状态
- 自动生成 UUID、REALITY 密钥和 short ID
- 配置文件权限为 `600`，systemd 服务包含基础安全加固
- 输出 VLESS URL 和 Mihomo 配置

## 系统要求

- 使用 systemd 的 Linux 发行版
- 使用 `root` 用户运行
- 包管理器：`apt-get`、`dnf`、`yum`、`zypper`、`pacman` 或 `apk`
- 支持常见的 x86、ARM、MIPS、PowerPC、RISC-V 和 s390x 架构

## 使用方法

打开交互菜单：

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/irasutoya/xray-reality-installer/main/install.sh)
```

使用默认参数非交互安装：

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/irasutoya/xray-reality-installer/main/install.sh) --install
```

指定端口和 REALITY 目标域名：

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/irasutoya/xray-reality-installer/main/install.sh) \
  --install --port 443 --domain itunes.apple.com
```

如果已安装，脚本默认拒绝在非交互模式下覆盖。确认覆盖时添加 `--force`：

```shell
bash install.sh --install --force
```

## 命令选项

```text
--install                    非交互安装
-p, --port PORT             监听端口，默认 443
-u, --uuid UUID             指定 VLESS UUID
-d, --domain DOMAIN         REALITY 目标域名
-f, --fingerprint FP        客户端指纹
-v, --version VERSION       指定 Xray 版本，例如 v26.3.27
-y, --force                 覆盖已有安装
--status                     查看服务状态
--show-config                重新输出客户端配置
--uninstall                  卸载
-h, --help                   查看帮助
```

旧版单横线参数（如 `-port`、`-uuid`、`-domain`、`-fingerprint`、`-uninstall`）继续兼容。

## 安装路径

- 主目录：`/root/xray`
- 可执行文件：`/root/xray/bin/xray`
- 服务端配置：`/root/xray/config/config.json`
- 客户端元数据：`/root/xray/config/client.json`
- systemd 服务：`/etc/systemd/system/xray.service`

配置和客户端元数据仅允许 root 读取。`client.json` 不包含 REALITY 私钥。

## REALITY 目标域名

默认目标域名为 `itunes.apple.com`。固定域名并不适合所有服务器；如需调整，应优先选择与服务器位于同一 ASN、支持 TLS 1.3、连接稳定且证书域名匹配的站点。

## 故障排除

```shell
systemctl status xray --no-pager -l
journalctl -u xray -n 100 --no-pager
bash install.sh --status
bash install.sh --show-config
```

还需要确认服务器防火墙和云平台安全组已放行监听端口。

## 本地检查

```shell
bash -n install.sh
bash tests/install_test.sh
```

## 免责声明

本项目仅供合法的学习、研究和网络运维用途。使用者必须遵守服务器所在地及使用所在地的法律法规，并自行承担使用责任。
