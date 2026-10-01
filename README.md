# luci-app-vnt2web

这是一个仅用于管理 `vnt2_web` 客户端的 OpenWrt LuCI 插件。

自动下载和安装固定使用 `vnt-dev/vnt` 仓库的 `2.0.10` 版本。状态页另外查询并展示最新预览版；该查询仅供查看，不会改变下载目标。

## 安装方法

### OpenWrt 24.10.x
系统-软件包-上传软件包，安装即可。

### OpenWrt 25.12.x (APK)

Release 只发布 `.apk` 文件，不再单独发布 `.pem` 公钥。首次安装请先确认 APK
来源可信，将 APK 上传到路由器 `/tmp/` 后通过 SSH 执行：

```sh
apk add --allow-untrusted /tmp/luci-app-vnt2web_*.apk
apk info luci-app-vnt2web
```

`--allow-untrusted` 只用于首次安装该 APK，安装包会把自己的公钥写入
`/etc/apk/keys/luci-app-vnt2web.pem`。因此不需要单独上传 `.pem` 文件；后续版本在使用
同一把固定签名密钥构建时，可直接通过 LuCI 或 SSH 安装和升级。LuCI 软件包上传页面
不会自动添加 `--allow-untrusted` 参数。

## 自动设备 ID

Web 配置未填写 `device_id` 时，插件在启动前将系统自动 ID 持久化到
`/etc/machine-id`，并让 `/var/lib/dbus/machine-id` 指向该文件。首次启用会沿用
当前有效 ID；没有有效 ID 时才随机生成。重启和升级继续使用同一个 ID，不需要
在 TOML 中手动填写。这也会稳定系统 D-Bus machine ID。

用户显式填写的 `device_id` 仍优先。持久化失败或已有持久化文件无效时，服务
会停止启动并记录错误，避免意外改变身份。升级和卸载不会删除系统 machine ID。
本机制不清理服务器上已存在的 IP 冲突记录；旧记录需要等待释放或由服务器管理方处理。

## 卸载方法

OpenWrt 24.10.x：

```sh
opkg remove luci-app-vnt2web
```

OpenWrt 25.12.x：

```sh
apk del luci-app-vnt2web
```
