# 译览 TranslateBrowser

iOS / Windows 浏览器，打开 YouTube 后自动提取字幕并用 LLM 做双语叠加翻译。

支持服务商：ChatGPT (OpenAI) · Claude (Anthropic) · OpenRouter · Grok (xAI)

| 平台 | 目录 | 产物 |
|------|------|------|
| iOS | `TranslateBrowser/` | IPA（见 `scripts/build-ipa.sh` 与 `.github/workflows/build-ipa.yml`） |
| Windows | `desktop/` | NSIS 安装包 / 便携版 exe（见 `.github/workflows/build-windows.yml`） |

## iOS IPA 构建速览

本地（需 macOS + Xcode + `brew install xcodegen`）与 CI 使用同一脚本：

```bash
scripts/build-ipa.sh all       # doctor → generate → archive → package → verify
scripts/build-ipa.sh generate  # 也可单独执行某一阶段
```

产物输出到 `build/TranslateBrowser-<版本>-<构建号>.ipa`（未签名，附 `.sha256` 校验和），
可用 AltStore / Sideloadly / TrollStore 侧载。版本号取自最近的 git tag，构建号在 CI 中取
run number。可用环境变量覆盖配置，详见脚本头部注释。

## Windows 桌面端速览

```bash
cd desktop
npm install
npm start          # 开发运行
npm run dist:win   # 打包 Windows（需在 Windows 或 CI 上）
```

详细说明见 [`desktop/README.md`](desktop/README.md)。
