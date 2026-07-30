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
assert.match(browserView, /case "tbFullscreenChanged":\s*guard let isFullscreen = message\.body as\? Bool else \{ return \}\s*Task \{ @MainActor in\s*OrientationLock\.shared\.setFullscreen\(isFullscreen, in: self\.webView\?\.window\?\.windowScene\)\s*\}/s,
  'BrowserView must forward fullscreen state with the originating web view scene');
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
assert.match(orientationLock, /let mask: UIInterfaceOrientationMask = isFullscreen \? \.landscape : \.allButUpsideDown/,
  'Fullscreen must lock to landscape and exit must restore normal rotation');
assert.match(orientationLock, /func setFullscreen\(_ isFullscreen: Bool, in scene: UIWindowScene\?\)[\s\S]*guard let scene else \{ return \}/,
  'Fullscreen must operate on the originating scene rather than an arbitrary connected scene');
assert.match(orientationLock, /masks\[scene\.session\.persistentIdentifier\] = mask/,
  'Fullscreen orientation state must be kept per scene');
assert.match(orientationLock, /requestGeometryUpdate\(\.iOS\(interfaceOrientations: mask\)\)/,
  'Orientation changes must be applied to the active window scene');
assert.match(appDelegate, /supportedInterfaceOrientationsFor[\s\S]*OrientationLock\.shared\.mask\(for: window\?\.windowScene\)/,
  'UIKit must consult the app orientation lock');
assert.match(app, /@UIApplicationDelegateAdaptor\(AppDelegate\.self\)/,
  'The SwiftUI app must install its UIKit app delegate');

assert.match(subtitleScript, /func fetchBodyViaWebView[\s\S]*withCheckedThrowingContinuation[\s\S]*callAsyncJavaScript[\s\S]*completionHandler:\s*\{ result in[\s\S]*case \.success\(let value\): continuation\.resume\(returning: value\)[\s\S]*case \.failure\(let error\): continuation\.resume\(throwing: error\)/,
  'In-page caption downloads must bridge WKWebView callAsyncJavaScript completion results instead of receiving Void from its async overlay');
assert.match(subtitleScript, /func fetchBodyViaWebView[\s\S]*guard let raw = rawValue as\? String/,
  'The bridged in-page response must be decoded before URLSession fallback');

console.log('iOS fullscreen/landscape source contract passed');
