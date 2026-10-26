# QuickSend 原生客户端（v2.1.0 预览版）

v2.1.0 预览版已发布：<https://github.com/Adamisatree/QuickSend/releases/tag/v2.1.0>。多平台 CI、构建和资产打包通过；真实设备安装/传输测试与独立安全审计仍未完成，且发布包未配置生产签名，因此不是稳定或生产就绪版本。

## v2.1 更新

- 桌面端默认接收位置使用系统 Downloads 目录；Android/iOS 默认应用 Documents/Downloads 沙盒目录。移动端可从传输记录通过系统分享菜单另存至公开“下载”目录。
- 在“传输记录 → 文件保存位置”查看实际路径、选取其他文件夹或恢复默认。文件保存在所选目录的 `QuickSend/Received/<transfer-id>` 子目录中；修改只影响之后收到的文件。
- 传输记录显示每次接收的完整保存路径；Windows/macOS/Linux 可直接打开保存文件夹，Android/iOS 可使用分享菜单将文件保存至用户可见位置。
- 发布包：Windows per-user 安装程序 EXE（NSIS）、Linux DEB、macOS DMG 和 Android APK。Windows/macOS 包未签名；Android APK 未使用生产签名密钥。

## 已有功能

- UDP 广播发现局域网中继（默认 UDP 4322），手动 IPv4 连接回退；中继默认 TCP 4321。
- 私密房间、设备名称、群组邀请/群聊、文件与文件夹传输。
- 每次发送选择严格保密或高速模式。严格模式通过端到端加密保护文件内容与文件名/路径；高速模式让文件内容以明文经过中继，仅限可信网络，切勿用于敏感文件。
- 接收方逐次批准；收到文件后校验大小和 SHA-256。高速模式下清单也经过中继，因此 SHA-256 不能抵御能够修改内容和清单的恶意中继。

## 开发与验证

```sh
cd client
./tool/bootstrap_platforms.sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter run -d <device>
```

CI 成功只表示相应 runner 上的分析、测试或编译通过，并不能证明真实设备安装、下载位置权限、LAN 自动发现或传输正常。此协议未经过独立安全审计；不要用于高风险/受监管数据。Android/iOS 后台持续传输尚未实现；请让移动应用保持前台。iOS 分发需要 Apple 团队与 provisioning profile，当前未配置。
