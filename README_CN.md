# TypeNo

[English](README.md)

**免费、开源、隐私优先的 macOS 语音输入工具。**

![TypeNo 宣传图](assets/hero.webp)

一个极简的 macOS 语音输入应用。按下 Control 说话，TypeNo 在本地完成转录，然后自动粘贴到你正在使用的应用中——全程不到一秒。

官方网站：[https://typeno.com](https://typeno.com)

特别感谢 [marswave ai 的 coli 项目](https://github.com/marswaveai/coli) 提供本地语音识别能力。

## 使用方式

1. **短按 Control** 开始录音
2. **再短按 Control** 停止
3. 文字自动转录并粘贴到当前应用（同时复制到剪贴板）
4. 录音时，TypeNo 会贴合 Mac 刘海区域显示：刘海两侧保留录制标识和计时，鼠标 hover 或点击后从刘海向下展开预览
5. 停止后，TypeNo 仍会基于完整录音做最终转录，再粘贴到当前应用

就这么简单。没有窗口，没有设置，没有账号。

## 刘海灵动岛预览

TypeNo 现在使用贴合 Mac 刘海的灵动岛式悬浮层：

- **空闲历史入口：** 未录制时，可以点击刘海旁边的历史图标，查看最近转录内容并重新复制。
- **录制状态：** 录制中会在刘海区域保留录制标识和已录制时间。
- **展开预览：** hover 或点击刘海区域后，预览面板会从刘海向下展开；长文本会在面板内换行和滚动。
- **全屏友好：** 当前应用处于全屏模式时，默认隐藏空闲历史悬浮入口；只有开始录制后才展示录制灵动岛。
- **降低发热：** 实时预览只在预览面板展开时启动；停止录制后仍会用完整音频做最终转录。

## 安装

### 方式一：直接下载

- [下载 TypeNo for macOS](https://github.com/musterkill007/TypeNo-new/releases/latest)
- 下载最新的 `TypeNo.dmg`（推荐）或 `TypeNo.app.zip`
- 打开 DMG 并将 `TypeNo.app` 拖到 `/Applications`，或者解压 `TypeNo.app.zip`
- 打开 TypeNo

面向公开分发时，建议发布经过 Apple 签名和公证的安装包，这样 macOS 可以直接打开，减少 Gatekeeper 提示。

### 语音识别引擎设置

TypeNo 使用 [coli](https://github.com/marswaveai/coli) 进行本地语音识别。

首次启动时，TypeNo 会自动检查本地语音依赖：

- [Node.js](https://nodejs.org) / npm — 用于安装和运行 coli
- [ffmpeg](https://ffmpeg.org) — 用于音频转换
- [coli](https://github.com/marswaveai/coli) — 本地语音识别引擎

如果依赖缺失，TypeNo 会在录制前弹出应用内设置向导。检测到 Homebrew 时，应用可以自动安装 `ffmpeg`；npm 和 ffmpeg 就绪后，也可以自动安装 `coli`。如果缺少 Node.js 或 Homebrew，向导会提供安装链接和一键复制的命令。

仍然可以手动安装：

```bash
brew install ffmpeg
npm install -g @marswave/coli
```

> **Node 24+：** 如果遇到 `sherpa-onnx-node` 错误，请从源码编译安装：
> ```bash
> npm install -g @marswave/coli --build-from-source
> ```

### 首次启动

TypeNo 需要两个一次性授权：
- **麦克风** — 录制你的声音
- **辅助功能** — 将文字粘贴到应用中

首次启动时，应用会自动引导你完成授权。

### 常见问题：Coli 模型下载失败

语音模型从 GitHub 下载。如果你的网络无法访问 GitHub，下载会失败。

**解决方法：** 在代理工具中开启 **TUN 模式**（也叫增强模式），确保系统级流量正常路由。然后重试安装：

```bash
npm install -g @marswave/coli
```

### 常见问题：辅助功能权限无效

部分用户在**系统设置 → 隐私与安全性 → 辅助功能**中开启 TypeNo 后仍无法使用——这是 macOS 的一个已知 bug。解决方法：

1. 在列表中选中 **TypeNo**
2. 点击 **−** 删除它
3. 点击 **+**，从 `/Applications` 重新添加 TypeNo

![辅助功能权限修复](assets/accessibility-fix.gif)

### 方式二：从源码构建

```bash
git clone https://github.com/musterkill007/TypeNo-new.git
cd TypeNo-new
scripts/generate_icon.sh
scripts/build_app.sh
```

应用位于 `dist/TypeNo.app`。移动到 `/Applications/` 以获得持久权限。

### 维护者发布

发布可下载安装包时，推送版本 tag：

```bash
git tag v1.5.1
git push origin v1.5.1
```

GitHub Actions 会自动构建，并将 `TypeNo.dmg` 和 `TypeNo.app.zip` 上传到 Release。

## 操作方式

| 操作 | 触发方式 |
|---|---|
| 开始/停止录音 | 短按 `Control`（< 300ms，不按其他键） |
| 开始/停止录音 | 菜单栏 → Record |
| 展开录制预览 | 录制中 hover 或点击刘海灵动岛 |
| 查看历史记录 | 未录制时点击刘海旁边的历史入口 |
| 查看流式转录 | 录制中展开刘海预览；最终粘贴仍基于完整文件转录 |
| 选择麦克风 | 菜单栏 → 麦克风 → 自动 / 指定设备 |
| 转录文件 | 拖拽 `.m4a`/`.mp3`/`.wav`/`.aac` 到菜单栏图标 |
| 检查更新 | 菜单栏 → Check for Updates... |
| 退出 | 菜单栏 → Quit（`⌘Q`） |

## 设计理念

TypeNo 只做一件事：语音 → 文字 → 粘贴。没有多余的 UI，没有偏好设置，没有配置项。最快的打字方式就是不打字。

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=musterkill007/TypeNo-new&type=Date)](https://star-history.com/#musterkill007/TypeNo-new&Date)

## 许可证

GNU General Public License v3.0
