# QuickSend

> **v2.1.0 预览版已发布**：<https://github.com/Adamisatree/QuickSend/releases/tag/v2.1.0>。包含 Windows 安装程序 EXE、Linux DEB、macOS DMG 和 Android APK。代码 CI 与包构建通过；真实设备安装/传输验证、独立安全审计及生产签名尚未完成，因此不是稳定或生产就绪版本。

QuickSend 是面向可信局域网的原生 Flutter 应用，支持中文界面、局域网设备发现、私密房间、群组聊天和文件传输。每次发送可选择严格保密（文件端到端加密）或高速传输（文件内容明文经过局域网中继；仅限可信网络）。旧版 Web/Electron/Capacitor 仍保留在仓库，但不属于 v2.x 主客户端。

## v2.1 文件保存与安装体验

- 桌面端默认使用系统 Downloads 目录；Android/iOS 默认应用 Documents/Downloads 沙盒目录（移动端可用分享菜单另存至公开“下载”目录）。也可在“传输记录 → 文件保存位置”中选择其他目录。
- 界面显示完整保存目录；文件按传输编号归档至 `QuickSend/Received/<transfer-id>`，桌面端可从传输记录直接打开文件夹。更改位置只影响之后收到的文件。
- 发布包：Windows 安装程序 EXE、Linux DEB、macOS DMG、Android APK。Windows/macOS/Android 包未使用发布者生产签名；iOS 需要 Apple 签名身份与配置文件。

## 局域网连接

一台可信设备启动临时中继（默认 TCP 4321），其他设备用 UDP 4322 广播发现，或手动填写 IP/端口。所有成员需通过私密渠道取得同一高熵房间密钥。访客网络隔离、防火墙、VPN 或跨子网配置可能阻止自动发现或连接；设备名称广播不经认证，不能代替房间身份校验。

高速模式会把文件内容以明文交给局域网中继；请勿用于敏感数据。严格保密模式仍会向中继暴露连接元数据与文件大小。协议尚未经过独立安全审计，移动端后台传输尚未实现。

## 开发与验证

```sh
cd client
./tool/bootstrap_platforms.sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter run -d <device>
```

CI 编译和自动化测试不能证明真实设备发现/传输、安装体验、后台行为或签名有效。发布检查见 [`client/RELEASE_CHECKLIST.md`](client/RELEASE_CHECKLIST.md)，安全说明见 [`client/SECURITY_REVIEW.md`](client/SECURITY_REVIEW.md)。
