# luci-app-vnt2web

这是一个仅用于管理 `vnt2_web` 客户端的 OpenWrt LuCI 插件。

运行时配置文件固定为 `/etc/config/vnt2.toml`。

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

### OpenWrt 25.12.0

将 `.apk` 文件上传到路由器，例如上传到 `/tmp/`，然后执行：

```sh
apk add --allow-untrusted /tmp/luci-app-vnt2web*.apk
apk info luci-app-vnt2web
```
## 卸载方法

OpenWrt 24.10.x：

```sh
opkg remove luci-app-vnt2web
```

OpenWrt 25.12.0：

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
- OpenWrt 25.12.0 生成 `.apk`

## LuCI 菜单位置

安装完成后，在 LuCI 中进入：

```text
VPN -> VNT2
```
