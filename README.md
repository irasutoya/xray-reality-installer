# Xray REALITY 一键安装脚本

在使用 systemd 的 Linux 服务器上安装和管理 VLESS + Vision + REALITY。

## 功能

- 交互菜单与非交互安装
- 自动识别 Xray 官方发布架构
- 下载官方 `.dgst` 文件并校验 SHA-256
- 写入系统前执行 `xray run -test -config`
- 使用 `nobody` 用户运行，通过 `CAP_NET_BIND_SERVICE` 监听 443
- 安装失败时恢复原二进制、配置、服务文件和服务状态
- 输出 VLESS URL 与 Mihomo 配置

## 默认参数

- 端口：`443`
- REALITY 目标域名：`itunes.apple.com`
- 客户端指纹：`chrome`
- Xray 版本：GitHub 最新稳定版

## 系统要求

- 使用 systemd 的 Linux 发行版
- 使用 `root` 用户执行
- 支持 `apt-get`、`dnf`、`yum`、`zypper` 或 `pacman`

## 使用方法

交互菜单：

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/irasutoya/xray-reality-installer/main/install.sh)
```

使用默认参数直接安装：

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/irasutoya/xray-reality-installer/main/install.sh) --install
```

指定参数：

```shell
bash install.sh --install \
  --port 443 \
  --domain itunes.apple.com \
  --fingerprint chrome
```

覆盖已有安装：

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

路径与 XTLS 官方安装器保持一致：

- Xray：`/usr/local/bin/xray`
- 服务端配置：`/usr/local/etc/xray/config.json`
- 客户端元数据：`/usr/local/etc/xray/client.json`
- systemd 服务：`/etc/systemd/system/xray.service`

旧版脚本的 `/root/xray` 会在新版本安装成功后清理。

## 管理与排错

```shell
bash install.sh --status
bash install.sh --show-config
bash install.sh --uninstall
systemctl status xray --no-pager -l
journalctl -u xray -n 100 --no-pager
```

还需要在服务器防火墙和云平台安全组中放行监听端口。

## 上游参考

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- [XTLS/Xray-install](https://github.com/XTLS/Xray-install)
- [XTLS/REALITY](https://github.com/XTLS/REALITY)
- [REALITY 配置文档](https://xtls.github.io/config/transports/reality.html)

## 本地检查

```shell
bash -n install.sh
```

## 免责声明

本项目仅供合法的学习、研究和网络运维用途。使用者必须遵守服务器所在地及使用所在地的法律法规，并自行承担使用责任。
