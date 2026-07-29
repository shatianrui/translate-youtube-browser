# 译览 TranslateBrowser

iOS / Windows 浏览器，打开 YouTube 后自动提取字幕并用 LLM 做双语叠加翻译。

支持服务商：ChatGPT (OpenAI) · Claude (Anthropic) · OpenRouter · Grok (xAI)

| 平台 | 目录 | 产物 |
|------|------|------|
| iOS | `TranslateBrowser/` | IPA（见 `.github/workflows/build-ipa.yml`） |
| Windows | `desktop/` | NSIS 安装包 / 便携版 exe（见 `.github/workflows/build-windows.yml`） |

## Windows 桌面端速览

```bash
cd desktop
npm install
npm start          # 开发运行
npm run dist:win   # 打包 Windows（需在 Windows 或 CI 上）
```

详细说明见 [`desktop/README.md`](desktop/README.md)。
