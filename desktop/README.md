# 译览字幕台 · Windows 桌面端

独立 YouTube 字幕提取与翻译工具。粘贴视频链接后，应用通过原生网络通道读取公开字幕轨，调用 ChatGPT / Claude / OpenRouter / Grok 翻译，并在本地查看或导出双语字幕。

## 功能

- 粘贴视频链接并选择可用字幕轨
- 主进程 InnerTube 多客户端通道，不依赖页面注入或浏览器播放状态
- 原文与译文按时间轴并排显示
- 导出双语 SRT 或 TXT
- 翻译请求从主进程发送，避免 Electron `file://` CORS 限制
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

1. 打开「翻译设置」，选择服务商并填写 API Key
2. 粘贴任意 YouTube 视频链接，点击「获取字幕」
3. 选择字幕轨并点击「载入此轨」
4. 点击「翻译全部」，可导出双语 SRT 或 TXT

API Key 只保存在本机用户目录，不会上传到本项目服务器。

## 字幕为空？

应用只使用 InnerTube 的 Android、iOS 与嵌入式客户端读取公开字幕轨，不会尝试控制 YouTube 播放器。若仍提示为空，请确认该视频确实公开提供字幕；受地区、年龄或权限限制的视频可能无法读取。
