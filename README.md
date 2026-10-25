# 1Melon

自用的本地密码管理器（macOS 桌面端）：登录、银行卡、安全笔记、身份信息、SSH 密钥、API Token、Wi-Fi 七类条目，带密码生成器、TOTP 两步验证码和安全报告。保险库是本机的一个加密文件，不依赖任何云服务。

> 状态：设计阶段，还没有代码。UI 设计稿在 [`docs/ui/`](docs/ui/)（用浏览器打开 `Lockbox.dc.html`，设计稿里的产品名还叫 Lockbox）。

## 技术选型

按项目基线（v3）「桌面应用」：Electron + electron-builder，界面 Vue 3 + Vite，TypeScript，测试 Vitest。Mac arm64 先行。

## 本地运行

还没有代码。

## 发布

按项目基线「桌面应用」：tag `vX.Y.Z`，在门户上点发布（melon-ci `desktop-release`），安装包和 `latest.json` 放对象存储，GitHub Release 存档。发布流水线等有了可运行的版本再接。

## 安全说明

- 设计稿 `docs/ui/` 里的条目（账号、卡号、证件号、密钥）全部是**虚构的演示数据**，不是真实凭据。
- 真实的保险库文件（`*.lbx`）和任何密钥永远不进 git，见 `.gitignore`。

## 已知限制

- 没有 Apple 开发者签名，做不了静默自动更新；有新版时只提示下载。
