import { BILINGUAL_OVERLAY_JS, CAPTION_TRACKS_JS } from './overlay.js';
import { fetchSubtitles, fetchTracksViaAndroidVR } from './subtitle.js';
import { PROVIDERS, translateTexts, translateLive } from './translation.js';

const DEFAULT_URL = 'https://www.youtube.com';
const SEARCH_PREFIX = 'https://www.google.com/search?q=';

/** @type {string} */
let guestPreloadPath = '';

const els = {
  tabsBar: document.getElementById('tabsBar'),
  webviewHost: document.getElementById('webviewHost'),
  addressInput: document.getElementById('addressInput'),
  addressForm: document.getElementById('addressForm'),
  progressFill: document.getElementById('progressFill'),
  statusBar: document.getElementById('statusBar'),
  btnBack: document.getElementById('btnBack'),
  btnForward: document.getElementById('btnForward'),
  btnReload: document.getElementById('btnReload'),
  btnBookmark: document.getElementById('btnBookmark'),
  btnBookmarks: document.getElementById('btnBookmarks'),
  btnSubtitles: document.getElementById('btnSubtitles'),
  btnRetranslate: document.getElementById('btnRetranslate'),
  btnSettings: document.getElementById('btnSettings'),
  btnNewTab: document.getElementById('btnNewTab'),
  settingsDialog: document.getElementById('settingsDialog'),
  settingsForm: document.getElementById('settingsForm'),
  settingProvider: document.getElementById('settingProvider'),
  settingApiKey: document.getElementById('settingApiKey'),
  settingModel: document.getElementById('settingModel'),
  settingTargetLang: document.getElementById('settingTargetLang'),
  bookmarksDialog: document.getElementById('bookmarksDialog'),
  bookmarksList: document.getElementById('bookmarksList'),
  bookmarksEmpty: document.getElementById('bookmarksEmpty'),
  bookmarksClose: document.getElementById('bookmarksClose'),
  subtitleDialog: document.getElementById('subtitleDialog'),
  subtitleList: document.getElementById('subtitleList'),
  subtitleEmpty: document.getElementById('subtitleEmpty'),
  subtitleClose: document.getElementById('subtitleClose'),
};

/**
 * Per-provider credentials: { provider, targetLang, credentials: { [storeKey]: { apiKey, model } } }
 * @type {{ provider: string, targetLang: string, credentials: Record<string, {apiKey: string, model: string}> }}
 */
let settings = {
  provider: 'ChatGPT (OpenAI)',
  targetLang: '中文',
  credentials: {},
};

function currentApiKey() {
  const meta = PROVIDERS[settings.provider];
  const key = meta?.storeKey || 'openai';
  return settings.credentials[key]?.apiKey || '';
}

function currentModel() {
  const meta = PROVIDERS[settings.provider];
  const key = meta?.storeKey || 'openai';
  return settings.credentials[key]?.model || '';
}

/** @type {{ id: string, title: string, urlString: string }[]} */
let bookmarks = [];

let tabSeq = 0;
/** @type {Map<string, TabState>} */
const tabs = new Map();
/** @type {string | null} */
let activeTabId = null;

/**
 * @typedef {object} TabState
 * @property {string} id
 * @property {boolean} isPrivate
 * @property {string} urlText
 * @property {string} pageTitle
 * @property {number} estimatedProgress
 * @property {boolean} canGoBack
 * @property {boolean} canGoForward
 * @property {Array<{start:number,duration:number,text:string,translation:?string}>} subtitles
 * @property {number|null} currentIndex
 * @property {string} statusMessage
 * @property {boolean} isTranslating
 * @property {string|null} lastLoadedVideoID
 * @property {number} extractionToken
 * @property {number} translationEpoch
 * @property {Set<number>} translatingIndices
 * @property {string|null} pendingCapturedBody
 * @property {HTMLElement} webview
 */

function uid() {
  tabSeq += 1;
  return `tab-${Date.now()}-${tabSeq}`;
}

function hostTitle(urlText) {
  try {
    return new URL(urlText).host || urlText;
  } catch {
    return urlText || '新标签页';
  }
}

function displayTitle(tab) {
  return tab.pageTitle || hostTitle(tab.urlText);
}

function setStatus(tab, message, kind = '') {
  tab.statusMessage = message || '';
  if (tab.id !== activeTabId) return;
  els.statusBar.textContent = tab.statusMessage || '打开 YouTube 视频页自动提取双语字幕';
  els.statusBar.classList.toggle('busy', kind === 'busy');
  els.statusBar.classList.toggle('error', kind === 'error');
}

function normalizeAddress(text) {
  let value = text.trim();
  if (!value) return null;
  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(value)) {
    value = value.includes('.')
      ? `https://${value}`
      : `${SEARCH_PREFIX}${encodeURIComponent(value)}`;
  }
  return value;
}

function videoIDFromURL(urlString) {
  let url;
  try {
    url = new URL(urlString);
  } catch {
    return null;
  }
  const host = (url.host || '').toLowerCase();
  const valid = (raw) => {
    if (!raw) return null;
    const id = String(raw).split('?')[0];
    if (id.length < 10 || id.length > 12) return null;
    if (!/^[A-Za-z0-9_-]+$/.test(id)) return null;
    return id;
  };
  if (host.includes('youtu.be')) {
    return valid(url.pathname.split('/').filter(Boolean)[0]);
  }
  const parts = url.pathname.split('/').filter(Boolean);
  if (parts.length >= 2 && ['shorts', 'embed', 'live', 'v'].includes(parts[0])) {
    return valid(parts[1]);
  }
  return valid(url.searchParams.get('v'));
}

function isYouTubeURL(urlString) {
  try {
    const host = new URL(urlString).host.toLowerCase();
    return host.includes('youtube.com') || host.includes('youtu.be') || host.includes('youtube-nocookie.com');
  } catch {
    return false;
  }
}

function targetLanguageHints(lang) {
  switch (lang) {
    case '中文':
    case '繁體中文':
      return ['zh', 'zh-Hans', 'zh-Hant', 'zh-CN', 'zh-TW'];
    case '日本語':
      return ['ja'];
    case '한국어':
      return ['ko'];
    case 'Français':
      return ['fr'];
    case 'Deutsch':
      return ['de'];
    case 'Español':
      return ['es'];
    case 'Русский':
      return ['ru'];
    case 'English':
      return ['en'];
    default:
      return [];
  }
}

function pickBestTrack(tracks, targetLang) {
  const hints = targetLanguageHints(targetLang);
  const isTarget = (t) => hints.some((h) => String(t.languageCode || '').startsWith(h));
  return (
    tracks.find((t) => t.kind !== 'asr' && String(t.languageCode || '').startsWith('en')) ||
    tracks.find((t) => t.kind !== 'asr' && !isTarget(t)) ||
    tracks.find((t) => t.kind !== 'asr') ||
    tracks.find((t) => String(t.languageCode || '').startsWith('en')) ||
    tracks[0]
  );
}

async function pushSubtitlesToPage(tab) {
  const payload = tab.subtitles.map((s, i) => {
    const nextStart = (i + 1 < tab.subtitles.length) ? tab.subtitles[i + 1].start : null;
    const rawEnd = s.start + Math.max(s.duration, 0.05);
    const e = nextStart != null ? Math.min(rawEnd, nextStart) : rawEnd;
    return {
      s: s.start,
      d: s.duration,
      e,
      o: s.text,
      t: s.translation || '',
    };
  });
  const json = JSON.stringify(payload);
  try {
    await tab.webview.executeJavaScript(
      `window.__tbSetSubtitles && window.__tbSetSubtitles(${json})`,
    );
  } catch {
    // page may be navigating
  }
}

async function clearSubtitleState(tab) {
  tab.extractionToken += 1;
  tab.translationEpoch += 1;
  tab.subtitles = [];
  tab.currentIndex = null;
  tab.lastLoadedVideoID = null;
  tab.translatingIndices = new Set();
  tab.pendingCapturedBody = null;
  setStatus(tab, '');
  try {
    await tab.webview.executeJavaScript('window.__tbClearSubtitles && window.__tbClearSubtitles()');
  } catch {
    // ignore
  }
}

// ---- Realtime cue translation ----

async function translateRealtimeCues(tab, startIdx) {
  const apiKey = currentApiKey();
  if (!apiKey || !tab.subtitles.length) return;
  const epoch = tab.translationEpoch;

  const count = Math.min(2, tab.subtitles.length - startIdx);
  if (count <= 0) return;

  const indices = [];
  for (let i = startIdx; i < startIdx + count; i++) {
    if (i >= tab.subtitles.length) break;
    if (tab.subtitles[i].translation) continue;
    if (tab.translatingIndices.has(i)) continue;
    indices.push(i);
  }
  if (!indices.length) return;

  for (const i of indices) tab.translatingIndices.add(i);

  try {
    const texts = indices.map((i) => tab.subtitles[i].text);
    const translated = await translateLive({
      provider: settings.provider,
      apiKey,
      model: currentModel(),
      texts,
      targetLang: settings.targetLang,
    });
    if (epoch !== tab.translationEpoch) return;
    for (let j = 0; j < indices.length; j++) {
      const idx = indices[j];
      if (idx < tab.subtitles.length && !tab.subtitles[idx].translation) {
        tab.subtitles[idx].translation = translated[j] || '';
      }
    }
    await pushSubtitlesToPage(tab);
  } catch {
    // silently fail for realtime
  } finally {
    for (const i of indices) tab.translatingIndices.delete(i);
  }
}

async function prefetchTranslations(tab, currentIdx) {
  const apiKey = currentApiKey();
  if (!apiKey || !tab.subtitles.length) return;
  const epoch = tab.translationEpoch;

  const WINDOW_SIZE = 20;
  const MAX_SECONDS = 75;
  const startTime = tab.subtitles[currentIdx]?.start ?? 0;
  const endIdx = Math.min(currentIdx + WINDOW_SIZE, tab.subtitles.length);

  const needTranslation = [];
  for (let i = currentIdx; i < endIdx; i++) {
    if (tab.subtitles[i].start - startTime > MAX_SECONDS) break;
    if (tab.subtitles[i].translation) continue;
    if (tab.translatingIndices.has(i)) continue;
    needTranslation.push(i);
  }
  if (!needTranslation.length) return;

  const chunkSize = 20;
  for (let c = 0; c < needTranslation.length; c += chunkSize) {
    if (epoch !== tab.translationEpoch) return;
    const chunk = needTranslation.slice(c, c + chunkSize);
    for (const i of chunk) tab.translatingIndices.add(i);

    try {
      const texts = chunk.map((i) => tab.subtitles[i].text);
      const translated = await translateTexts({
        provider: settings.provider,
        apiKey,
        model: currentModel(),
        texts,
        targetLang: settings.targetLang,
      });
      if (epoch !== tab.translationEpoch) return;
      for (let j = 0; j < chunk.length; j++) {
        const idx = chunk[j];
        if (idx < tab.subtitles.length && !tab.subtitles[idx].translation) {
          tab.subtitles[idx].translation = translated[j] || '';
        }
      }
      await pushSubtitlesToPage(tab);
    } catch {
      // continue
    } finally {
      for (const i of chunk) tab.translatingIndices.delete(i);
    }
  }
}

async function translateAll(tab) {
  const apiKey = currentApiKey();
  if (!apiKey) {
    setStatus(tab, `请在设置中填写 ${settings.provider} 的 API Key`, 'error');
    openSettings();
    return;
  }
  if (!tab.subtitles.length) return;

  // Clear existing translations and restart
  for (const sub of tab.subtitles) sub.translation = null;
  tab.translationEpoch += 1;
  tab.translatingIndices = new Set();
  tab.isTranslating = true;
  els.btnRetranslate.disabled = true;

  const epoch = tab.translationEpoch;
  try {
    const chunkSize = 20;
    for (let start = 0; start < tab.subtitles.length; start += chunkSize) {
      if (epoch !== tab.translationEpoch) return;
      const end = Math.min(start + chunkSize, tab.subtitles.length);
      const texts = tab.subtitles.slice(start, end).map((s) => s.text);
      const translated = await translateTexts({
        provider: settings.provider,
        apiKey,
        model: currentModel(),
        texts,
        targetLang: settings.targetLang,
      });
      if (epoch !== tab.translationEpoch) return;
      for (let i = start; i < end; i++) {
        tab.subtitles[i].translation = translated[i - start] || '';
      }
      await pushSubtitlesToPage(tab);
    }
    setStatus(tab, `翻译完成（${settings.provider}）`);
  } catch (err) {
    setStatus(tab, `翻译失败: ${err.message || err}`, 'error');
  } finally {
    tab.isTranslating = false;
    if (tab.id === activeTabId) syncChrome();
  }
}

async function waitForAdsToFinish(webview) {
  for (let i = 0; i < 60; i++) {
    try {
      const adPlaying = await webview.executeJavaScript(`
        (function() {
          var p = document.getElementById('movie_player') || document.querySelector('.html5-video-player');
          if (!p) return false;
          var cls = p.className || '';
          return cls.indexOf('ad-showing') >= 0 || cls.indexOf('ad-interrupting') >= 0;
        })()
      `);
      if (!adPlaying) return;
    } catch {
      return;
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
}

async function extractAndTranslate(tab) {
  const token = ++tab.extractionToken;
  tab.translationEpoch += 1;
  const videoID = tab.lastLoadedVideoID;
  tab.subtitles = [];
  tab.currentIndex = null;
  tab.translatingIndices = new Set();
  try {
    await tab.webview.executeJavaScript('window.__tbClearSubtitles && window.__tbClearSubtitles()');
  } catch {
    // ignore
  }

  // Wait out pre-roll ads
  await waitForAdsToFinish(tab.webview);
  if (token !== tab.extractionToken) return;

  let tracks = [];
  for (let attempt = 0; attempt < 20; attempt++) {
    if (token !== tab.extractionToken) return;
    try {
      const json = await tab.webview.executeJavaScript(CAPTION_TRACKS_JS);
      const decoded = JSON.parse(json || '[]');
      if (Array.isArray(decoded) && decoded.length) {
        tracks = decoded;
        break;
      }
    } catch {
      // keep polling
    }
    await new Promise((r) => setTimeout(r, 350));
  }

  if (!tracks.length && videoID) {
    try {
      tracks = await fetchTracksViaAndroidVR(videoID);
    } catch {
      tracks = [];
    }
  }

  if (token !== tab.extractionToken) return;
  if (!tracks.length) {
    setStatus(tab, '该视频没有可用字幕', 'error');
    return;
  }

  const track = pickBestTrack(tracks, settings.targetLang);

  try {
    try {
      await tab.webview.executeJavaScript(BILINGUAL_OVERLAY_JS);
    } catch {
      // ignore
    }

    const subs = await fetchSubtitles(track, videoID, tab.webview, tab.pendingCapturedBody);
    tab.pendingCapturedBody = null;
    if (token !== tab.extractionToken) return;
    if (!subs.length) {
      setStatus(tab, '字幕内容为空（可点刷新重试，或确认视频有字幕）', 'error');
      return;
    }
    tab.subtitles = subs;
    await pushSubtitlesToPage(tab);
    setStatus(tab, '');
    // Realtime translation starts via tbActiveIndex events
  } catch (err) {
    if (token !== tab.extractionToken) return;
    setStatus(tab, `字幕获取失败: ${err.message || err}`, 'error');
  }
}

function onURLChanged(tab, urlString) {
  if (!urlString) return;
  tab.urlText = urlString;
  if (tab.id === activeTabId) {
    els.addressInput.value = urlString;
  }
  renderTabs();

  if (!isYouTubeURL(urlString)) {
    clearSubtitleState(tab);
    return;
  }
  const videoID = videoIDFromURL(urlString);
  if (!videoID) return;
  if (videoID === tab.lastLoadedVideoID) return;
  tab.lastLoadedVideoID = videoID;
  extractAndTranslate(tab);
}

function createWebview(isPrivate) {
  const webview = document.createElement('webview');
  webview.setAttribute('allowpopups', 'true');
  webview.setAttribute('webpreferences', 'contextIsolation=yes, javascript=yes, webSecurity=yes');
  if (guestPreloadPath) {
    webview.setAttribute('preload', guestPreloadPath);
  }
  webview.setAttribute(
    'partition',
    isPrivate
      ? `private-${Date.now()}-${Math.random().toString(36).slice(2)}`
      : 'persist:main',
  );
  webview.classList.add('browser-view');
  return webview;
}

function wireWebview(tab) {
  const { webview } = tab;

  webview.addEventListener('dom-ready', async () => {
    try {
      await webview.executeJavaScript(BILINGUAL_OVERLAY_JS);
    } catch {
      // ignore
    }
  });

  webview.addEventListener('did-navigate', (e) => {
    onURLChanged(tab, e.url);
  });
  webview.addEventListener('did-navigate-in-page', (e) => {
    onURLChanged(tab, e.url);
  });
  webview.addEventListener('did-finish-load', () => {
    try {
      const url = webview.getURL();
      onURLChanged(tab, url);
    } catch {
      // ignore
    }
  });

  webview.addEventListener('page-title-updated', (e) => {
    tab.pageTitle = e.title || '';
    renderTabs();
  });

  webview.addEventListener('did-start-loading', () => {
    tab.estimatedProgress = 0.08;
    if (tab.id === activeTabId) syncChrome();
  });
  webview.addEventListener('did-stop-loading', () => {
    tab.estimatedProgress = 1;
    if (tab.id === activeTabId) syncChrome();
  });

  webview.addEventListener('did-get-response-details', () => {
    if (tab.estimatedProgress < 0.7) tab.estimatedProgress = 0.55;
    if (tab.id === activeTabId) syncChrome();
  });

  webview.addEventListener('ipc-message', (e) => {
    if (e.channel === 'tbUrlChanged') {
      const url = Array.isArray(e.args) ? e.args[0] : e.args;
      onURLChanged(tab, url);
    } else if (e.channel === 'tbActiveIndex') {
      const idx = Array.isArray(e.args) ? e.args[0] : e.args;
      tab.currentIndex = typeof idx === 'number' && idx >= 0 ? idx : null;
      if (els.subtitleDialog.open) renderSubtitleList(tab);

      // Realtime translation: translate current + next 1-2 cues immediately
      if (typeof idx === 'number' && idx >= 0 && tab.subtitles.length) {
        translateRealtimeCues(tab, idx);
        prefetchTranslations(tab, idx);
      }
    } else if (e.channel === 'tbCaptionBody') {
      const data = Array.isArray(e.args) ? e.args[0] : e.args;
      if (data && data.body) {
        tab.pendingCapturedBody = data.body;
      }
    }
  });

  webview.addEventListener('new-window', (e) => {
    e.preventDefault();
    if (e.url) newTab(e.url, tab.isPrivate);
  });
}

function renderTabs() {
  els.tabsBar.innerHTML = '';
  for (const tab of tabs.values()) {
    const el = document.createElement('div');
    el.className = `tab${tab.id === activeTabId ? ' active' : ''}${tab.isPrivate ? ' private' : ''}`;
    el.title = tab.urlText;
    el.innerHTML = `
      <span class="tab-title"></span>
      <button class="tab-close" title="关闭" aria-label="关闭">✕</button>
    `;
    el.querySelector('.tab-title').textContent = displayTitle(tab);
    el.addEventListener('click', (ev) => {
      if (ev.target.closest('.tab-close')) return;
      selectTab(tab.id);
    });
    el.querySelector('.tab-close').addEventListener('click', (ev) => {
      ev.stopPropagation();
      closeTab(tab.id);
    });
    els.tabsBar.appendChild(el);
  }
}

function syncChrome() {
  const tab = activeTabId ? tabs.get(activeTabId) : null;
  if (!tab) return;

  els.addressInput.value = tab.urlText;
  els.btnBack.disabled = !tab.canGoBack;
  els.btnForward.disabled = !tab.canGoForward;
  els.btnRetranslate.disabled = !tab.subtitles.length || tab.isTranslating;
  els.btnSubtitles.disabled = !tab.subtitles.length;
  els.btnBookmark.textContent = isBookmarked(tab.urlText) ? '★' : '☆';

  const progress = tab.estimatedProgress;
  els.progressFill.style.width = `${Math.max(0, Math.min(1, progress)) * 100}%`;
  els.progressFill.classList.toggle('visible', progress > 0 && progress < 1);

  setStatus(tab, tab.statusMessage, tab.isTranslating ? 'busy' : '');

  try {
    tab.canGoBack = webviewCan(tab.webview, 'canGoBack');
    tab.canGoForward = webviewCan(tab.webview, 'canGoForward');
    els.btnBack.disabled = !tab.canGoBack;
    els.btnForward.disabled = !tab.canGoForward;
  } catch {
    // ignore
  }
}

function webviewCan(webview, method) {
  if (typeof webview[method] === 'function') return !!webview[method]();
  return false;
}

function selectTab(id) {
  activeTabId = id;
  for (const tab of tabs.values()) {
    tab.webview.classList.toggle('active', tab.id === id);
  }
  renderTabs();
  syncChrome();
}

function newTab(urlString = DEFAULT_URL, isPrivate = false) {
  const id = uid();
  const webview = createWebview(isPrivate);
  els.webviewHost.appendChild(webview);

  /** @type {TabState} */
  const tab = {
    id,
    isPrivate,
    urlText: urlString,
    pageTitle: '',
    estimatedProgress: 0,
    canGoBack: false,
    canGoForward: false,
    subtitles: [],
    currentIndex: null,
    statusMessage: '',
    isTranslating: false,
    lastLoadedVideoID: null,
    extractionToken: 0,
    translationEpoch: 0,
    translatingIndices: new Set(),
    pendingCapturedBody: null,
    webview,
  };
  tabs.set(id, tab);
  wireWebview(tab);
  webview.src = urlString;
  selectTab(id);
  return tab;
}

function closeTab(id) {
  const tab = tabs.get(id);
  if (!tab) return;
  tab.extractionToken += 1;
  tab.translationEpoch += 1;
  tab.webview.remove();
  tabs.delete(id);
  if (!tabs.size) {
    newTab();
    return;
  }
  if (activeTabId === id) {
    const remaining = [...tabs.keys()];
    selectTab(remaining[remaining.length - 1]);
  } else {
    renderTabs();
  }
}

function loadActiveFromAddress() {
  const tab = tabs.get(activeTabId);
  if (!tab) return;
  const url = normalizeAddress(els.addressInput.value);
  if (!url) return;
  tab.urlText = url;
  tab.lastLoadedVideoID = null;
  tab.webview.src = url;
  syncChrome();
}

function isBookmarked(urlString) {
  return bookmarks.some((b) => b.urlString === urlString);
}

async function toggleBookmark() {
  const tab = tabs.get(activeTabId);
  if (!tab) return;
  if (isBookmarked(tab.urlText)) {
    bookmarks = bookmarks.filter((b) => b.urlString !== tab.urlText);
  } else {
    bookmarks.push({
      id: uid(),
      title: displayTitle(tab),
      urlString: tab.urlText,
    });
  }
  await window.tbDesktop.setBookmarks(bookmarks);
  syncChrome();
}

function renderBookmarks() {
  els.bookmarksList.innerHTML = '';
  const empty = bookmarks.length === 0;
  els.bookmarksEmpty.hidden = !empty;
  els.bookmarksList.hidden = empty;
  for (const bookmark of bookmarks) {
    const li = document.createElement('li');
    li.innerHTML = `
      <div class="meta">
        <div class="title"></div>
        <div class="url"></div>
      </div>
      <button class="remove" title="删除" aria-label="删除">✕</button>
    `;
    li.querySelector('.title').textContent = bookmark.title;
    li.querySelector('.url').textContent = bookmark.urlString;
    li.addEventListener('click', (ev) => {
      if (ev.target.closest('.remove')) return;
      const tab = tabs.get(activeTabId);
      if (tab) {
        tab.urlText = bookmark.urlString;
        tab.lastLoadedVideoID = null;
        tab.webview.src = bookmark.urlString;
      }
      els.bookmarksDialog.close();
      syncChrome();
    });
    li.querySelector('.remove').addEventListener('click', async (ev) => {
      ev.stopPropagation();
      bookmarks = bookmarks.filter((b) => b.id !== bookmark.id);
      await window.tbDesktop.setBookmarks(bookmarks);
      renderBookmarks();
      syncChrome();
    });
    els.bookmarksList.appendChild(li);
  }
}

function formatTime(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

function renderSubtitleList(tab) {
  els.subtitleList.innerHTML = '';
  const empty = !tab.subtitles.length;
  els.subtitleEmpty.hidden = !empty;
  els.subtitleList.hidden = empty;
  tab.subtitles.forEach((sub, i) => {
    const item = document.createElement('div');
    item.className = `subtitle-item${i === tab.currentIndex ? ' active' : ''}`;
    item.innerHTML = `
      <div class="time"></div>
      <div class="orig"></div>
      <div class="trans"></div>
    `;
    item.querySelector('.time').textContent = formatTime(sub.start);
    item.querySelector('.orig').textContent = sub.text;
    item.querySelector('.trans').textContent = sub.translation || '';
    els.subtitleList.appendChild(item);
  });
}

function openSettings() {
  els.settingProvider.innerHTML = '';
  for (const name of Object.keys(PROVIDERS)) {
    const opt = document.createElement('option');
    opt.value = name;
    opt.textContent = name;
    els.settingProvider.appendChild(opt);
  }
  els.settingProvider.value = settings.provider;

  const meta = PROVIDERS[settings.provider];
  const key = meta?.storeKey || 'openai';
  const cred = settings.credentials[key] || {};
  els.settingApiKey.value = cred.apiKey || '';
  els.settingApiKey.placeholder = meta?.placeholder || 'sk-...';
  els.settingModel.value = cred.model || '';
  els.settingModel.placeholder = `默认 ${meta?.defaultModel || ''}`;
  els.settingTargetLang.value = settings.targetLang;
  els.settingsDialog.showModal();
}

function onProviderChange() {
  const providerName = els.settingProvider.value;
  const meta = PROVIDERS[providerName];
  const key = meta?.storeKey || 'openai';
  const cred = settings.credentials[key] || {};
  els.settingApiKey.value = cred.apiKey || '';
  els.settingApiKey.placeholder = meta?.placeholder || 'sk-...';
  els.settingModel.value = cred.model || '';
  els.settingModel.placeholder = `默认 ${meta?.defaultModel || ''}`;
}

async function saveSettings() {
  const providerName = els.settingProvider.value;
  const meta = PROVIDERS[providerName];
  const key = meta?.storeKey || 'openai';

  settings.provider = providerName;
  settings.targetLang = els.settingTargetLang.value;
  if (!settings.credentials[key]) settings.credentials[key] = {};
  settings.credentials[key].apiKey = els.settingApiKey.value.trim();
  settings.credentials[key].model = els.settingModel.value.trim();

  await window.tbDesktop.setSettings(settings);
  els.settingsDialog.close();
}

function bindUI() {
  els.addressForm.addEventListener('submit', (e) => {
    e.preventDefault();
    loadActiveFromAddress();
  });
  els.btnBack.addEventListener('click', () => {
    const tab = tabs.get(activeTabId);
    if (tab?.canGoBack) tab.webview.goBack();
  });
  els.btnForward.addEventListener('click', () => {
    const tab = tabs.get(activeTabId);
    if (tab?.canGoForward) tab.webview.goForward();
  });
  els.btnReload.addEventListener('click', () => {
    const tab = tabs.get(activeTabId);
    if (!tab) return;
    tab.lastLoadedVideoID = null;
    tab.webview.reload();
  });
  els.btnNewTab.addEventListener('click', (e) => newTab(DEFAULT_URL, e.shiftKey));
  els.btnBookmark.addEventListener('click', () => toggleBookmark());
  els.btnBookmarks.addEventListener('click', () => {
    renderBookmarks();
    els.bookmarksDialog.showModal();
  });
  els.bookmarksClose.addEventListener('click', () => els.bookmarksDialog.close());
  els.btnSubtitles.addEventListener('click', () => {
    const tab = tabs.get(activeTabId);
    if (!tab) return;
    renderSubtitleList(tab);
    els.subtitleDialog.showModal();
  });
  els.subtitleClose.addEventListener('click', () => els.subtitleDialog.close());
  els.btnRetranslate.addEventListener('click', () => {
    const tab = tabs.get(activeTabId);
    if (tab) translateAll(tab);
  });
  els.btnSettings.addEventListener('click', () => openSettings());

  els.settingProvider.addEventListener('change', onProviderChange);

  els.settingsForm.addEventListener('submit', async (e) => {
    const submitter = e.submitter;
    if (submitter && submitter.value === 'cancel') return;
    e.preventDefault();
    await saveSettings();
  });
  document.getElementById('settingsSave').addEventListener('click', async (e) => {
    e.preventDefault();
    await saveSettings();
  });

  setInterval(() => {
    if (!activeTabId) return;
    const tab = tabs.get(activeTabId);
    if (!tab) return;
    try {
      const back = webviewCan(tab.webview, 'canGoBack');
      const forward = webviewCan(tab.webview, 'canGoForward');
      if (back !== tab.canGoBack || forward !== tab.canGoForward) {
        tab.canGoBack = back;
        tab.canGoForward = forward;
        syncChrome();
      }
    } catch {
      // ignore
    }
  }, 400);

  window.tbDesktop.onMenuNewTab(() => newTab());
  window.tbDesktop.onMenuNewPrivateTab(() => newTab(DEFAULT_URL, true));
  window.tbDesktop.onMenuCloseTab(() => {
    if (activeTabId) closeTab(activeTabId);
  });
  window.tbDesktop.onMenuOpenYouTube(() => newTab(DEFAULT_URL));
  window.tbDesktop.onOpenExternalUrl((url) => newTab(url));
}

async function boot() {
  guestPreloadPath = await window.tbDesktop.getGuestPreloadPath();
  settings = await window.tbDesktop.getSettings();
  // Migrate legacy flat settings to per-provider credentials
  if (!settings.credentials) {
    settings.credentials = {};
  }
  if (settings.apiKey && !Object.keys(settings.credentials).length) {
    const meta = PROVIDERS[settings.provider];
    const key = meta?.storeKey || 'openai';
    settings.credentials[key] = { apiKey: settings.apiKey, model: settings.model || '' };
    delete settings.apiKey;
    delete settings.model;
    await window.tbDesktop.setSettings(settings);
  }
  bookmarks = await window.tbDesktop.listBookmarks();
  bindUI();
  newTab(DEFAULT_URL);
}

boot();
