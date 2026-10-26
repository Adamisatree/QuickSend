# QuickSend

> **v2.0.0 预览版已发布**：Flutter 原生客户端现支持中文界面、局域网设备发现、群组聊天与文件传输。它是预览版，不是稳定或生产就绪版本；尚未完成真实设备测试或独立安全审查。详见 [`client/README.md`](client/README.md) 与 [GitHub Release](https://github.com/Adamisatree/QuickSend/releases/tag/v2.0.0)。

QuickSend 让同一局域网内的设备发现临时中继并加入私密房间，创建群组聊天、发送文件。发送方每次可选择严格保密（端到端加密）或高速传输（文件内容明文经过局域网中继）；高速模式只适用于可信网络。旧版 Web/Electron/Capacitor 客户端仍保留在仓库中，但 v2.0 的主要开发目标是 `client/` 内的 Flutter 原生应用。

## 使用 QuickSend v2.0 预览版

1. 在一台可信设备启动 QuickSend 局域网中继，其他设备通过广播发现其名称，或手动填写 IP/端口。
2. 通过私密渠道分享强随机房间密钥；所有成员输入相同密钥后加入房间。
3. 选择在线设备发送文件，或创建群组邀请成员进行加密聊天。
4. 每次发送选择严格保密或高速模式；接收方确认后开始接收。

自动发现只展示未认证的 UDP 广播信息，不是身份验证。访客网络隔离、防火墙、VPN 或不同子网可能阻止广播/连接；TCP/UDP 默认端口及回退步骤见客户端说明。

## 开发与验证

```sh
cd client
./tool/bootstrap_platforms.sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter run -d <device>
```

CI 构建只能说明代码通过相应 runner 的编译和自动化检查，不能证明真实设备间的发现/传输、安装体验、移动后台行为或签名状态。当前没有本地 Flutter/Dart SDK，因此需依赖 CI 验证。发布前清单见 [`client/RELEASE_CHECKLIST.md`](client/RELEASE_CHECKLIST.md)，安全限制见 [`client/SECURITY_REVIEW.md`](client/SECURITY_REVIEW.md)。

## 旧版说明

旧版 Node/Web、Electron 和 Capacitor 代码仍在仓库根目录，其发布工作流与 Flutter v2.0 客户端分开。请勿将旧版页面或旧版打包脚本视为 v2.0 客户端。v1.1.0 Flutter 预览版历史资产在 [GitHub Releases](https://github.com/Adamisatree/QuickSend/releases/tag/v1.1.0)；那是预览包，并非 v2.0 稳定版。
