# luci-app-vnt2web

这是一个仅用于管理 `vnt2_web` 客户端的 OpenWrt LuCI 插件。

默认运行时配置文件为 `/etc/config/vnt2web.toml`。LuCI 创建额外客户端配置时，会在同一目录使用 `vnt2web-*.toml` 文件名保存。

`/etc/config/vnt2` 是 OpenWrt LuCI/UCI 配置文件，继续用于保存页面设置；它不是 `vnt2_web` 的运行时 TOML。默认客户端运行时 TOML 为 `/etc/config/vnt2web.toml`，额外配置只允许使用同目录的 `vnt2web-*.toml`。

本插件只管理 `vnt2_web` 客户端，不包含或管理 `vnts2` 服务端。插件不会创建、安装、读取、修改、迁移或删除 `/etc/config/vnts2.toml`；设备上已有的该文件属于独立服务的配置。

配置列表只显示 `vnt2web.toml` 和 `vnt2web-*.toml`。默认文件不可删除，额外配置可以编辑、启动、重启和删除；其他 TOML 文件不会被扫描或管理。

首次启动时组网实例列表保持为空。对于仍会把 `--conf` 自动注册为实例的旧版下载程序，init 启动流程会在本机 API 就绪后移除其已停止的默认实例卡片，但不会删除 `/etc/config/vnt2web.toml`，也不会中断用户主动启动的实例。

## 包名称说明

OpenWrt 软件包管理器中的实际包名固定为：

- `luci-app-vnt2web`

无论是在 `系统 -> 软件包` 页面中搜索，还是使用 `opkg` / `apk` 查询，实际包名都应当使用 `luci-app-vnt2web`。

## 发布文件说明

工作流会先校验 OpenWrt 实际产物唯一且以 `luci-app-vnt2web` 为前缀，
再按 Release tag 统一重命名为固定的发布文件名。
软件包名前缀始终为：

- `luci-app-vnt2web`

最终发布文件名规则：

- `luci-app-vnt2web_<版本>-x86_64.ipk`
- `luci-app-vnt2web_<版本>-x86_64.apk`

其中 `<版本>` 取自 Release tag，并去掉开头的 `v` 或 `V`。例如 tag 为
`v2.0.40` 时，发布文件为：

- `luci-app-vnt2web_2.0.40-x86_64.ipk`
- `luci-app-vnt2web_2.0.40-x86_64.apk`

## 上传与版本说明

- 手动上传由 LuCI 暂存到 `/etc/vnt2/upload`，随后交给后台 worker 校验并安装，不会阻塞页面请求。
- 安装成功后程序位于 `/usr/bin/vnt2_web`，并自动排队重启服务。
- 本地版本来自 `/etc/config/vnt2-web.version`；若程序被替换或修改，本地版本会显示为空，而不是显示过期版本。

## Web 访问令牌

- `vnt2_web` 的 Web API 通过访问令牌保护。
- 首次使用或令牌为空时，插件会自动生成随机令牌并保存到 `web_token`。
- LuCI 基本设置中的“访问 Token”可以直接手动输入；右侧星号按钮会生成新的随机令牌。
- 状态页“访问地址”会自动携带 URL 编码后的 `?token=...`，点击链接可直接进入 Web 页面。

## 自动下载版本说明

- 下载版本填写 `latest` 时，只获取仓库官方稳定版 Latest，不会自动下载预发布版本。
- `latest` 只通过 GitHub 官方 `/releases/latest` 接口解析，该接口按定义排除预发布版本和草稿版本。
- `latest` 不设硬编码兜底版本；解析失败时报告失败，并回退到手动上传的程序。
- `Gitee`、`GitLab`、`Cloudflare R2` 的 Release 列表为手工同步，无法可靠标识稳定版，因此解析 `latest` 时会跳过这些镜像并回退 GitHub 官方接口；它们仍可用于下载指定 tag 的资产。

## 安装方法

### OpenWrt 24.10.x

将 `.ipk` 文件上传到路由器，例如上传到 `/tmp/`，然后执行：

```sh
opkg install /tmp/luci-app-vnt2web*.ipk
opkg info luci-app-vnt2web
opkg list-installed | grep luci-app-vnt2web
```

### OpenWrt 25.12.x (APK)

APK 使用本项目的签名密钥。首次安装前，需要先从同一个 GitHub Release 下载
`luci-app-vnt2web-apk-public-key.pem` 和对应的 `.sha256` 文件，并在电脑上核对公钥：

```sh
sha256sum --check luci-app-vnt2web-apk-public-key.sha256
```

将已核对的公钥上传到路由器 `/tmp/`，通过 SSH 安装到 APK 信任目录：

```sh
mkdir -p /etc/apk/keys
cp /tmp/luci-app-vnt2web-apk-public-key.pem /etc/apk/keys/luci-app-vnt2web.pem
chmod 0644 /etc/apk/keys/luci-app-vnt2web.pem
```

之后即可在 LuCI 软件包页面上传并安装签名后的 `.apk`。也可以通过 SSH 安装：

```sh
apk add /tmp/luci-app-vnt2web*.apk
apk info luci-app-vnt2web
```

之前发布的 APK 无法通过后来生成的公钥验证。需要立即安装旧包，或首次安装时无法
预先导入公钥，可以通过 SSH 对确认来源的文件执行
`apk add --allow-untrusted /tmp/luci-app-vnt2web_*.apk`；LuCI 软件包上传页面不会添加
`--allow-untrusted` 参数。新构建的 APK 会安装自己的公钥，因此使用固定签名密钥时，
后续版本可直接通过 LuCI 安装或升级。

GitHub Actions 发布签名 APK 需要仓库 Secret `VNT2WEB_APK_SIGNING_KEY_B64`，其值为
PEM 格式 EC 私钥的单行 Base64。私钥只能由维护者生成并保管，不能提交到仓库；
同一把私钥必须长期保留，否则新版本需要重新向设备导入新的公钥。维护者可在本地生成：

```sh
openssl ecparam -name prime256v1 -genkey -noout -out vnt2web-apk-private-key.pem
base64 -w 0 vnt2web-apk-private-key.pem
```

将第二条命令的输出设置为仓库 Secret；妥善保管私钥文件，不要提交到仓库。

## 卸载方法

OpenWrt 24.10.x：

```sh
opkg remove luci-app-vnt2web
```

OpenWrt 25.12.x：

```sh
apk del luci-app-vnt2web
```

## 在 OpenWrt 源码树中编译

本仓库根目录下仍有一层插件源码目录。将其中的 `luci-app-vnt2web/` 放入 OpenWrt 的 `package/` 目录，或放入自定义 feed 中，然后执行：

```sh
git clone <你的仓库地址> /tmp/luci-app-vnt2web-src
cp -a /tmp/luci-app-vnt2web-src/luci-app-vnt2web package/luci-app-vnt2web
make menuconfig
make package/luci-app-vnt2web/compile V=s
```

编译完成后：

- OpenWrt 24.10.x 生成 `.ipk`
- OpenWrt 25.12.5 生成签名 `.apk`

## LuCI 菜单位置

安装完成后，在 LuCI 中进入：

```text
VPN -> VNT2
```
