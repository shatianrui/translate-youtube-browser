import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (path) => readFileSync(new URL(path, import.meta.url), 'utf8');
const tabsManager = read('../TranslateBrowser/TabsManager.swift');
const tab = read('../TranslateBrowser/Tab.swift');
const browserView = read('../TranslateBrowser/BrowserView.swift');
const contentView = read('../TranslateBrowser/ContentView.swift');

assert.match(
  tabsManager,
  /static let defaultURL = "https:\/\/m\.youtube\.com\/"/,
  'new tabs must open the mobile YouTube homepage'
);
assert.match(
  tab,
  /@Published var showSubtitlePanel = false/,
  'the subtitle status/control panel must be opt-in'
);
assert.match(
  tab,
  /statusMessage = "未获取到字幕内容"/,
  'empty captions must have a concise neutral status'
);
assert.doesNotMatch(tab, /可能被 YouTube 限制/, 'do not present an unsupported blocked-caption claim');
assert.match(browserView, /iPhone; CPU iPhone OS/, 'YouTube must use an iPhone user agent');
assert.match(browserView, /userAgent\(for: navigationAction\.request\.url\)/, 'the user agent must be selected per navigation URL');
assert.match(browserView, /isYouTubeURL/, 'only YouTube navigation should receive the custom user agent');
assert.match(
  browserView,
  /config\.preferences\.isElementFullscreenEnabled\s*=\s*false/,
  'element fullscreen must stay disabled so video playback remains in the embedded page'
);
assert.doesNotMatch(
  contentView,
  /Label\("字幕", systemImage: "captions\.bubble"\)/,
  'do not float a subtitle entry button over playback by default'
);
assert.match(
  contentView,
  /showSubtitlePanel\.toggle\(\)[\s\S]*captions\.bubble/,
  'provide an unobtrusive toolbar control to opt in to subtitle controls'
);

console.log('browser defaults regression checks passed');
