# 译览 · Windows 桌面端

Electron 多标签浏览器，复刻 iOS「译览」的核心能力：打开 YouTube 视频后自动提取字幕，调用 ChatGPT / Claude / OpenRouter / Grok 翻译，并在播放器内叠加原文 + 译文双语字幕。

## 功能

- 多标签浏览（普通 / 隐私分区）
- 地址栏导航、前进 / 后退 / 刷新、收藏夹
- YouTube SPA 导航感知（切视频自动重新抽字幕）
- InnerTube `ANDROID_VR` 备用字幕通道（绕过部分 PoToken 限制）
- 播放器 DOM 内双语字幕（全屏仍可见）
- 设置项本机持久化（`electron-store`）

## 开发

需要 Node.js 20+。

```bash
cd desktop
npm install
npm start
```

跑核心单测：

```bash
npm test
```

## 打包 Windows

在 Windows 本机或 CI 上：

```bash
cd desktop
npm install
npm run dist:win
```

产物在 `desktop/dist/`：

| 文件 | 说明 |
|------|------|
| `TranslateBrowser-*-win-x64.exe` | NSIS 安装包 |
| `TranslateBrowser-*-portable.exe` | 便携版 |

GitHub Actions 工作流：`.github/workflows/build-windows.yml`（push / PR 变更 `desktop/**` 时构建，也可手动 `workflow_dispatch`）。

## 使用

1. 启动后默认打开 YouTube
2. 打开「设置」，选择服务商并填写 API Key
3. 进入任意带字幕的视频页，等待状态栏提示提取 / 翻译完成
4. 字幕会出现在播放器底部；也可点工具栏「字幕列表」浏览全文

API Key 只保存在本机用户目录，不会上传到本项目服务器。

## 字幕为空？

YouTube 现在对 WEB 字幕接口要求 PoToken。译览会：

1. 拦截播放器自己的 timedtext 下载（自带 PoToken）
2. 回退到页面「文字稿」面板抓取
3. 再尝试 InnerTube 多客户端备用通道

若仍提示为空，点工具栏刷新重试，并确认该视频本身有字幕。
