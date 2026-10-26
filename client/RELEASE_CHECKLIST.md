# QuickSend v2.1 发布检查清单

**状态：v2.1.0 预览版已发布**（<https://github.com/Adamisatree/QuickSend/releases/tag/v2.1.0>）。多平台代码 CI 和资产打包通过；真实设备安装/传输验证与独立安全审计仍未完成。不得将此预览版描述为稳定或生产就绪。

## v2.1 预览资产与功能

- Windows：NSIS per-user 安装程序 EXE（不再用 ZIP）；Linux：DEB；macOS：带 Applications 快捷方式的 DMG；Android：APK。iOS 暂不提供发布包。
- 桌面默认接收至系统 Downloads；Android/iOS 默认应用 Documents/Downloads 沙盒目录，并支持通过分享菜单导出；允许选择其他目录、恢复默认并显示实际目录。
- 接收文件放入 `<选择的目录>/QuickSend/Received/<transfer-id>`；桌面端显示实际传输目录并提供“打开文件夹”。设置只影响之后的接收，不移动旧文件。

## 预览发布记录

- [x] Flutter analyze/test、多平台代码 CI 与 Node CI 通过。
- [x] v2.1 release workflow 成功生成全部平台资产与 `SHA256SUMS`。
- [x] 检查资产清单：Windows x64/ARM64 EXE、Linux x64/ARM64 DEB、macOS Intel/Apple Silicon DMG、Android APK；没有 ZIP-only 桌面资产。
- [x] Release notes 标明预览状态、签名限制、高速模式明文风险、设备测试/审计未完成。
- [x] 未伪造或代填签名凭据；Windows/macOS/Android/iOS 生产签名仍需发布者自己的身份与配置。

## 提升稳定版前必须

- [ ] Windows x64/ARM64 安装器在干净设备上安装、启动、升级、卸载；快捷方式正确，中文向导正常，未签名警告清楚。
- [ ] Linux x64/ARM64 DEB 依赖、菜单入口、安装、启动与卸载实测。
- [ ] macOS Intel/Apple Silicon DMG 的 Applications 拖放快捷方式实测。
- [ ] Android、iOS、Windows、macOS、Linux 实测默认/自选/重置路径、权限拒绝、目录卸载、空格/中文路径、零字节/多文件/取消/清理。
- [ ] 确认界面路径与实际文件一致；同名文件按 transfer-id 隔离；磁盘不足/不可写时不得误报完成。
- [ ] 完成独立安全审查，发布者配置所需生产签名/公证凭据，再评估是否可称稳定版。

## 本地验证命令

```sh
cd client
./tool/bootstrap_platforms.sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test
```

CI 和包构建都不能替代真实设备安装/传输测试；完成预览发布后仍须先完成上述稳定版验收。
