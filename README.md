# luci-app-vnt2web

这是一个仅用于管理 `vnt2_web` 客户端的 OpenWrt LuCI 插件。

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

## 卸载方法

OpenWrt 24.10.x：

```sh
opkg remove luci-app-vnt2web
```

OpenWrt 25.12.x：

```sh
apk del luci-app-vnt2web
```
