import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const read = (relativePath) => readFileSync(join(root, relativePath), 'utf8');

const browserView = read('TranslateBrowser/BrowserView.swift');
const subtitleScript = read('TranslateBrowser/SubtitleExtractor.swift');
const app = read('TranslateBrowser/TranslateBrowserApp.swift');
const orientationLock = existsSync(join(root, 'TranslateBrowser/OrientationLock.swift'))
  ? read('TranslateBrowser/OrientationLock.swift')
  : '';
const appDelegate = existsSync(join(root, 'TranslateBrowser/AppDelegate.swift'))
  ? read('TranslateBrowser/AppDelegate.swift')
  : '';

assert.match(browserView, /contentController\.add\(context\.coordinator, name: "tbFullscreenChanged"\)/,
  'BrowserView must register the JavaScript fullscreen-state bridge');
assert.match(browserView, /case "tbFullscreenChanged":\s*guard let isFullscreen = message\.body as\? Bool else \{ return \}\s*Task \{ @MainActor in OrientationLock\.shared\.setFullscreen\(isFullscreen\) \}/s,
  'BrowserView must forward fullscreen state to the orientation lock');
assert.match(browserView, /createWebViewWith[\s\S]*navigationAction\.targetFrame == nil[\s\S]*webView\.load\(navigationAction\.request\)/,
  'target=_blank video/player navigation must be loaded in the current web view instead of being dropped');
assert.doesNotMatch(subtitleScript, /proto\.webkitEnterFullscreen\s*=/,
  'Do not replace native webkitEnterFullscreen: that prevents WKWebView from presenting its video player');
assert.match(subtitleScript, /function notifyFullscreen\(isFullscreen\) \{ post\('tbFullscreenChanged', !!isFullscreen\); \}/,
  'Fullscreen bridge must forward state to Swift');
assert.match(subtitleScript, /webkitbeginfullscreen[\s\S]*notifyFullscreen\(true\)/,
  'Native iOS video fullscreen entry must request landscape orientation');
assert.match(subtitleScript, /webkitendfullscreen[\s\S]*notifyFullscreen\(false\)/,
  'Native iOS video fullscreen exit must release the orientation lock');
assert.match(orientationLock, /mask = isFullscreen \? \.landscape : \.allButUpsideDown/,
  'Fullscreen must lock to landscape and exit must restore normal rotation');
assert.match(orientationLock, /requestGeometryUpdate\(\.iOS\(interfaceOrientations: mask\)\)/,
  'Orientation changes must be applied to the active window scene');
assert.match(appDelegate, /supportedInterfaceOrientationsFor[\s\S]*OrientationLock\.shared\.mask/,
  'UIKit must consult the app orientation lock');
assert.match(app, /@UIApplicationDelegateAdaptor\(AppDelegate\.self\)/,
  'The SwiftUI app must install its UIKit app delegate');

console.log('iOS fullscreen/landscape source contract passed');
