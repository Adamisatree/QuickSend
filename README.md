# QuickSend

> **v1.1 开发中：** 正在开发 Flutter 原生客户端（非 HTML UI），代码位于 [`client/`](client/README.md)。当前已发布版本仍是 v1.0.0；新客户端尚未完成全平台构建、签名或发布。Android/iOS 后台执行和 ARM64 桌面分发仍需单独验证，详见客户端说明。

QuickSend 是一个面向局域网的私密文件快传工具，包含轻量 Node.js 局域网服务、Windows/macOS 桌面应用壳和 Android 客户端。Windows 或 macOS 电脑可启动服务并作为传输中枢；同一网络中的设备用浏览器访问服务地址，或在 Android 应用中填写该地址后加入共享空间。桌面客户端自带服务，Android 应用作为局域网客户端。

## 快速开始

需要 Node.js 20 或更新版本。**由一台可信任的电脑运行服务**，该电脑和参与设备须处于同一 Wi-Fi / 有线局域网。可在 Windows 双击 `start-windows.bat`，在 macOS 双击 `start-macos.command`；首次启动会自动安装依赖。也可在终端执行：

```sh
npm install
npm start
```

启动后在终端查看打印出的 `http://局域网IP:4321`，其他设备用浏览器打开该地址。首次运行时，系统防火墙可能询问是否允许 Node.js 接受局域网连接，请允许**专用网络**访问。若端口被占用，可使用 `PORT=5000 npm start`（Windows PowerShell：`$env:PORT=5000; npm start`）。

### 一次传给多人

1. 每台设备打开同一个服务地址。
2. 其中一台点击“生成口令”，把口令通过你信任的方式发给同伴；各设备输入相同口令并加入空间。建议使用生成的随机口令，不要复用账号密码。
3. 选择一个或多个在线设备，挑选多个文件。接收者需要逐一同意后，文件才会开始发送。
4. 接收者在传输动态中下载收到的文件。

昵称保存在当前浏览器；共享口令只在当前页面内存中使用，刷新后需重新输入，口令本身不会发送到服务器（服务器仅收到用于分组的 SHA-256 摘要）。服务不提供跨网络发现；它不会扫描子网。在线列表只包含访问同一个服务、输入相同共享口令的设备。IP 地址是服务观察到的连接来源地址。

## 安全与隐私

- 每次传输都生成随机密钥；密钥分别通过 **X25519 + XSalsa20-Poly1305**（TweetNaCl box）封装给已接受的接收设备。文件内容再以 **XSalsa20-Poly1305**（TweetNaCl secretbox）逐块加密。接收设备的私钥仅保存在该设备内存中，因此同一共享空间里未被选中的成员也无法用空间口令解密文件。服务只转发公钥、密钥密文和文件密文，不持有私钥。
- 服务只在内存中转发密文，不写入上传文件或持久化传输记录。文件名、大小、昵称、IP 和在线状态等必要元数据由局域网服务转发。
- 默认部署为 HTTP，适合可信的私人局域网，并非匿名网络或公共 Wi-Fi 方案。端到端加密保护文件内容，但 HTTP 页面本身未经过服务器身份认证；若需要抵御局域网中主动攻击者，请将服务置于可信 HTTPS 反向代理后，通过有效 HTTPS 地址访问所有设备。反向代理需支持 WebSocket `/ws`，并将 `/api/info`、静态文件请求转发至 QuickSend。
- 口令是共享空间的访问凭据。短口令可能被猜测；请使用“生成口令”，只通过可信渠道分享，并在用完后更换。空间内的每位成员都能看到其他成员的 IP 和昵称。
- 局域网传输速度取决于 Wi-Fi / 网线与设备。文件按 256 KiB 分块加密；接收端在用户下载前将文件暂存在内存中，因此手机浏览器内存较少时不适合接收特别大的文件（服务端设有 20 GB 单文件上限）。

## 开发与维护

```sh
npm install
npm run build   # 将前端和密码学依赖打包至忽略的 public/assets/
npm start       # 自动构建后监听 0.0.0.0:4321
```

- `src/server.js`：局域网 HTTP/WebSocket 信令与临时文件块转发。
- `public/`：无框架的响应式界面、PWA manifest 与静态资源。
- `public/app.js`：客户端发现、审批、端到端加密和分块传输逻辑；通过 esbuild 打包 `tweetnacl`、`@noble/hashes`。

## 桌面与 Android 应用

- **Windows：** `npm run dist:desktop -- --win --x64` 生成 Windows 安装程序 `.exe`。
- **macOS：** `npm run dist:desktop -- --mac --x64 --arm64` 生成 Intel 与 Apple Silicon `.dmg`。
- **Android：** 安装 Android SDK/JDK 后运行 `npm run cap:sync`，再执行 `cd android && ./gradlew assembleDebug` 生成可侧载测试的 APK。首次打开应用时，填入运行 QuickSend 服务电脑显示的局域网地址。
- **Release 自动构建：** 推送 `v*` 标签后，GitHub Actions 自动构建 Windows EXE、Intel/Apple Silicon DMG 和 Android APK，并发布到 GitHub Release。

目前 Windows/macOS 构建未做代码签名或 notarization，系统可能显示安全提醒。Android 发布 APK 由 CI 使用调试签名，适合侧载测试，不适合 Play Store 发布；要正式上架或支持稳定升级，需要由项目所有者保管并配置自己的 Android 签名密钥。Android 客户端需连接局域网内运行 QuickSend 服务的电脑。
