import { BILINGUAL_OVERLAY_JS, CAPTION_TRACKS_JS } from './overlay.js';
import { fetchSubtitles, fetchTracksViaAndroidVR } from './subtitle.js';
import { PROVIDERS, translateTexts } from './translation.js';

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

/** @type {{ provider: string, apiKey: string, model: string, targetLang: string }} */
let settings = {
  provider: 'ChatGPT (OpenAI)',
  apiKey: '',
  model: '',
  targetLang: '中文',
};

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
  const payload = tab.subtitles.map((s) => ({
    s: s.start,
    d: s.duration,
    o: s.text,
    t: s.translation || '',
  }));
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
  tab.subtitles = [];
  tab.currentIndex = null;
  tab.lastLoadedVideoID = null;
  setStatus(tab, '');
  try {
    await tab.webview.executeJavaScript('window.__tbClearSubtitles && window.__tbClearSubtitles()');
  } catch {
    // ignore
  }
}

async function translateAll(tab) {
  if (!settings.apiKey) {
    setStatus(tab, `请在设置中填写 ${settings.provider} 的 API Key`, 'error');
    openSettings();
    return;
  }
  if (!tab.subtitles.length) return;
  tab.isTranslating = true;
  els.btnRetranslate.disabled = true;
  try {
    const chunkSize = 20;
    for (let start = 0; start < tab.subtitles.length; start += chunkSize) {
      const end = Math.min(start + chunkSize, tab.subtitles.length);
      const texts = tab.subtitles.slice(start, end).map((s) => s.text);
      setStatus(tab, `正在翻译 ${end}/${tab.subtitles.length}…`, 'busy');
      const translated = await translateTexts({
        provider: settings.provider,
        apiKey: settings.apiKey,
        model: settings.model,
        texts,
        targetLang: settings.targetLang,
      });
      for (let i = start; i < end; i++) {
        tab.subtitles[i].translation = translated[i - start] || '';
      }
      await pushSubtitlesToPage(tab);
      setStatus(tab, `已翻译 ${end}/${tab.subtitles.length}`, 'busy');
    }
    setStatus(tab, `翻译完成（${settings.provider}）`);
  } catch (err) {
    setStatus(tab, `翻译失败: ${err.message || err}`, 'error');
  } finally {
    tab.isTranslating = false;
    if (tab.id === activeTabId) syncChrome();
  }
}

async function extractAndTranslate(tab) {
  const token = ++tab.extractionToken;
  const videoID = tab.lastLoadedVideoID;
  setStatus(tab, '正在获取字幕…', 'busy');
  tab.subtitles = [];
  tab.currentIndex = null;
  try {
    await tab.webview.executeJavaScript('window.__tbClearSubtitles && window.__tbClearSubtitles()');
  } catch {
    // ignore
  }

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
    setStatus(tab, '正在通过备用通道获取字幕轨…', 'busy');
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
  setStatus(tab, `正在下载字幕（${track.languageCode || '?'}）…`, 'busy');

  try {
    // Ensure PoToken interceptors / player helpers are present (idempotent).
    try {
      await tab.webview.executeJavaScript(BILINGUAL_OVERLAY_JS);
    } catch {
      // ignore
    }

    setStatus(tab, '正在通过播放器通道获取字幕…', 'busy');
    const subs = await fetchSubtitles(track, videoID, tab.webview);
    if (token !== tab.extractionToken) return;
    if (!subs.length) {
      setStatus(tab, '字幕内容为空（可点刷新重试，或确认视频有字幕）', 'error');
      return;
    }
    tab.subtitles = subs;
    setStatus(tab, `已提取 ${subs.length} 条字幕，开始翻译…`, 'busy');
    await pushSubtitlesToPage(tab);
    await translateAll(tab);
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
    // Absolute path (not file://) — Electron resolves webview preload this way on Windows/Linux.
    webview.setAttribute('preload', guestPreloadPath);
  }
  // Private tabs use a non-persistent partition so cookies/cache die with the tab.
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

  // Approximate progress via Electron events when available.
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

  // Refresh nav capability from webview if available.
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
  els.settingApiKey.value = settings.apiKey;
  els.settingApiKey.placeholder = PROVIDERS[settings.provider]?.placeholder || 'sk-...';
  els.settingModel.value = settings.model;
  els.settingModel.placeholder = `默认 ${PROVIDERS[settings.provider]?.defaultModel || ''}`;
  els.settingTargetLang.value = settings.targetLang;
  els.settingsDialog.showModal();
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
  // Shift+click "+" opens a private tab.
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

  els.settingProvider.addEventListener('change', () => {
    const meta = PROVIDERS[els.settingProvider.value];
    els.settingApiKey.placeholder = meta?.placeholder || 'sk-...';
    els.settingModel.placeholder = `默认 ${meta?.defaultModel || ''}`;
  });

  els.settingsForm.addEventListener('submit', async (e) => {
    const submitter = e.submitter;
    if (submitter && submitter.value === 'cancel') return;
    e.preventDefault();
    settings = {
      provider: els.settingProvider.value,
      apiKey: els.settingApiKey.value.trim(),
      model: els.settingModel.value.trim(),
      targetLang: els.settingTargetLang.value,
    };
    await window.tbDesktop.setSettings(settings);
    els.settingsDialog.close();
  });
  document.getElementById('settingsSave').addEventListener('click', async (e) => {
    e.preventDefault();
    settings = {
      provider: els.settingProvider.value,
      apiKey: els.settingApiKey.value.trim(),
      model: els.settingModel.value.trim(),
      targetLang: els.settingTargetLang.value,
    };
    await window.tbDesktop.setSettings(settings);
    els.settingsDialog.close();
  });

  // Keep nav buttons fresh.
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
  bookmarks = await window.tbDesktop.listBookmarks();
  bindUI();
  newTab(DEFAULT_URL);
}

boot();
