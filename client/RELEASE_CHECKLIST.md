# QuickSend v2.1 发布检查清单

**状态：开发中。** v2.0.0 是当前已发布的 GitHub 预览版（<https://github.com/Adamisatree/QuickSend/releases/tag/v2.0.0>）。本分支的保存位置设置、桌面安装程序及 Linux DEB 尚未通过 CI、打包器完整验证或真实设备测试；不要创建 v2.1.0 标签，直到相关门槛通过。

## v2.1 目标

- Windows：Inno Setup 安装程序 EXE（不再用 ZIP）；Linux：DEB 安装包；macOS：带 Applications 快捷方式的 DMG；Android：APK。iOS 暂不提供发布包。
- 桌面端默认接收至系统 Downloads；Android/iOS 默认应用 Documents/Downloads 沙盒目录，并支持通过分享菜单导出；允许选择其他目录、恢复默认并显示实际目录。
- 接收文件放入 `<选择的目录>/QuickSend/Received/<transfer-id>`；桌面端显示实际传输目录并提供“打开文件夹”，移动端使用系统分享菜单。设置只影响之后的接收，不移动旧文件。

## 发布前必须完成

- [ ] Flutter analyze/test 和完整多平台 CI 通过；Node CI 通过。
- [ ] Windows x64/ARM64 安装器可安装、启动、升级、卸载；快捷方式正确，中文安装向导正常，未签名警告有说明。
- [ ] Linux x64/ARM64 DEB 安装、依赖、菜单入口、启动与卸载正常。
- [ ] macOS Intel/Apple Silicon DMG 的 Applications 拖放快捷方式可用。
- [ ] Android、iOS、Windows、macOS、Linux 实测默认下载路径、选择/重置目录、权限拒绝/目录卸载、带空格/中文路径、零字节和多文件、取消及清理。
- [ ] 验证界面路径与实际保存路径一致；同名文件由 transfer-id 子目录隔离；磁盘不足/路径不可写时不能误报完成。
- [ ] 所有包名、版本号、中文发布说明、SHA-256 清单准确，预览/签名限制清楚。
- [ ] 不伪造或代填签名凭据。Windows Authenticode、macOS Developer ID/notarization、Android 生产签名和 iOS provisioning 均需发布者自己的身份。

## 验证命令

```sh
cd client
./tool/bootstrap_platforms.sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test
```

`package_deb.sh` 可在 Linux 上单独测试 DEB 元数据；CI 编译和脚本测试都不能替代真实设备与干净机器安装测试。签名未配置时，2.1 若发布也必须继续作为明确标注的预览版。
