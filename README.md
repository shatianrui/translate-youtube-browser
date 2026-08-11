# 译览 TranslateBrowser

从零重写的 iOS 浏览器应用:打开 YouTube 视频并开启字幕(CC)后,自动提取字幕、调用 LLM
翻译,并在播放器上叠加**原文 + 译文**双语字幕。产物为未签名 IPA,可侧载安装。

支持的翻译服务商:ChatGPT (OpenAI) · Claude (Anthropic) · OpenRouter · Grok (xAI)

## 功能

- 内置浏览器:地址栏(网址 / 搜索)、前进后退、刷新、分享、加载进度
- YouTube 字幕捕获:注入脚本拦截 `/api/timedtext` 请求,解析 json3 字幕
- 双语叠加:隐藏原生字幕条,在播放器上渲染「原文 + 译文」双行字幕,随播放进度同步
- 翻译设置:服务商 / API Key / 模型 / 目标语言,均保存在本机
- 状态提示:翻译进度、完成数量、错误信息实时显示

## 目录结构

| 路径 | 说明 |
|------|------|
| `TranslateBrowser/Sources/` | Swift 源码(SwiftUI + WebKit) |
| `TranslateBrowser/Resources/` | 资源(图标、强调色) |
| `project.yml` | [xcodegen](https://github.com/yonaskolb/XcodeGen) 工程定义 |
| `scripts/build-ipa.sh` | 统一构建脚本(本地与 CI 共用) |
| `.github/workflows/build-ipa.yml` | CI:自动构建 IPA 并上传 artifact / release |

## 构建 IPA

### CI(推荐)

推送到 `main` 或手动触发 **Build IPA** 工作流,在 run 的 artifact 中下载
`TranslateBrowser-ipa`。推送 `v*` 标签会自动创建 GitHub Release 并附上 IPA。

### 本地(需 macOS + Xcode)

```bash
brew install xcodegen
scripts/build-ipa.sh all       # doctor → generate → archive → package → verify
scripts/build-ipa.sh generate  # 也可单独执行某一阶段后用 Xcode 打开工程
```

产物输出到 `build/TranslateBrowser-<版本>-<构建号>.ipa`(未签名,附 `.sha256` 校验和)。
版本号取自最近的 git tag,构建号在 CI 中取 run number,可用环境变量覆盖(见脚本头部注释)。

## 安装与使用

1. 用 [AltStore](https://altstore.io/)、[Sideloadly](https://sideloadly.io/) 或 TrollStore
   侧载 IPA(未签名包需要自签或越狱环境)。
2. 打开应用 → 右下角设置:选择服务商、填入 API Key、确认目标语言(默认简体中文)。
3. 打开任意 YouTube 视频,点开播放器的字幕(CC)按钮。
4. 应用自动提取字幕并分批翻译,播放器底部出现双语字幕;顶部状态条显示翻译进度。

> 系统要求 iOS 17.0+。API Key 仅存储在设备本地(UserDefaults),不会上传到任何第三方。
