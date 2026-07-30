import { fetchSubtitles, fetchTracksViaAndroidVR } from './subtitle.js';
import { PROVIDERS, translateTexts } from './translation.js';

const els = {
  player: document.getElementById('player'), videoUrl: document.getElementById('videoUrl'), urlForm: document.getElementById('urlForm'),
  emptyStage: document.getElementById('emptyStage'), trackSelect: document.getElementById('trackSelect'), btnReloadTrack: document.getElementById('btnReloadTrack'),
  status: document.getElementById('status'), captionOriginal: document.getElementById('captionOriginal'), captionTranslation: document.getElementById('captionTranslation'),
  cueTime: document.getElementById('cueTime'), cueText: document.getElementById('cueText'), btnSettings: document.getElementById('btnSettings'),
  settingsDialog: document.getElementById('settingsDialog'), settingsForm: document.getElementById('settingsForm'), settingProvider: document.getElementById('settingProvider'),
  settingApiKey: document.getElementById('settingApiKey'), settingModel: document.getElementById('settingModel'), settingTargetLang: document.getElementById('settingTargetLang'),
};

let settings = { provider: 'ChatGPT (OpenAI)', targetLang: '中文', credentials: {} };
let videoID = null;
let tracks = [];
let subtitles = [];
let activeIndex = -1;
let loadEpoch = 0;
const translating = new Set();

function setStatus(message, kind = '') { els.status.textContent = message; els.status.className = `status ${kind}`; }

function videoIDFromURL(raw) {
  try {
    const url = new URL(raw.trim());
    const valid = (id) => /^[A-Za-z0-9_-]{10,12}$/.test(id || '') ? id : null;
    if (url.hostname.toLowerCase().includes('youtu.be')) return valid(url.pathname.split('/').filter(Boolean)[0]);
    const path = url.pathname.split('/').filter(Boolean);
    return ['shorts', 'embed', 'live', 'v'].includes(path[0]) ? valid(path[1]) : valid(url.searchParams.get('v'));
  } catch { return null; }
}

function formatTime(seconds) {
  const value = Math.max(0, Number(seconds) || 0);
  return `${String(Math.floor(value / 60)).padStart(2, '0')}:${String(Math.floor(value % 60)).padStart(2, '0')}`;
}

function currentCredential() {
  const meta = PROVIDERS[settings.provider] || PROVIDERS['ChatGPT (OpenAI)'];
  return settings.credentials[meta.storeKey] || {};
}

function trackLabel(track) {
  const name = track.name?.simpleText || track.name?.runs?.map((run) => run.text).join('') || track.languageCode || 'Unknown';
  return `${name} (${track.languageCode || '?'})${track.kind === 'asr' ? ' · 自动生成' : ''}`;
}

function renderTracks() {
  els.trackSelect.replaceChildren();
  tracks.forEach((track, index) => {
    const option = document.createElement('option');
    option.value = String(index);
    option.textContent = trackLabel(track);
    els.trackSelect.appendChild(option);
  });
  els.trackSelect.disabled = !tracks.length;
  els.btnReloadTrack.disabled = !tracks.length;
}

function findCue(time) {
  let low = 0;
  let high = subtitles.length - 1;
  let candidate = -1;
  while (low <= high) {
    const middle = (low + high) >> 1;
    if (subtitles[middle].start <= time) { candidate = middle; low = middle + 1; } else high = middle - 1;
  }
  if (candidate < 0) return -1;
  const cue = subtitles[candidate];
  return time < cue.start + Math.max(cue.duration, 0.05) ? candidate : -1;
}

function renderCue(index) {
  const cue = subtitles[index];
  activeIndex = index;
  if (!cue) {
    els.captionOriginal.textContent = '';
    els.captionTranslation.textContent = '';
    els.cueTime.textContent = '--:--';
    return;
  }
  els.captionOriginal.textContent = cue.text;
  els.captionTranslation.textContent = cue.translation || '';
  els.cueTime.textContent = formatTime(cue.start);
  els.cueText.textContent = cue.translation ? `${cue.text}\n${cue.translation}` : cue.text;
  scheduleTranslation(index);
}

async function translateCue(index) {
  const credential = currentCredential();
  const cue = subtitles[index];
  if (!cue || cue.translation || translating.has(index) || !credential.apiKey) return;
  translating.add(index);
  try {
    const result = await translateTexts({ provider: settings.provider, apiKey: credential.apiKey, model: credential.model || '', texts: [cue.text], targetLang: settings.targetLang });
    if (subtitles[index] === cue) {
      cue.translation = result[0] || '';
      if (activeIndex === index) renderCue(index);
    }
  } catch (error) {
    if (activeIndex === index) setStatus(`翻译失败：${error.message || error}`, 'error');
  } finally { translating.delete(index); }
}

function scheduleTranslation(index) {
  if (!currentCredential().apiKey) {
    setStatus('已同步原文。请在翻译设置中填写 API Key 以显示译文。');
    return;
  }
  setStatus('实时翻译中…', 'busy');
  for (let offset = 0; offset < 3; offset += 1) translateCue(index + offset);
}

async function loadSelectedTrack() {
  const epoch = ++loadEpoch;
  const track = tracks[Number(els.trackSelect.value)];
  if (!track || !videoID) return;
  els.btnReloadTrack.disabled = true;
  setStatus(`正在载入 ${trackLabel(track)}…`, 'busy');
  try {
    const loaded = await fetchSubtitles(track, videoID, null);
    if (epoch !== loadEpoch) return;
    if (!loaded.length) throw new Error('该字幕轨没有可读取内容，请选择其他字幕轨。');
    subtitles = loaded;
    activeIndex = -1;
    els.captionOriginal.textContent = '';
    els.captionTranslation.textContent = '';
    setStatus(`已加载 ${subtitles.length} 条字幕，开始按播放时间同步。`);
  } catch (error) {
    if (epoch === loadEpoch) setStatus(`字幕载入失败：${error.message || error}`, 'error');
  } finally { if (epoch === loadEpoch) els.btnReloadTrack.disabled = false; }
}

async function loadCaptions(id) {
  const epoch = ++loadEpoch;
  videoID = id;
  tracks = [];
  subtitles = [];
  activeIndex = -1;
  renderTracks();
  setStatus('正在查找公开字幕轨…', 'busy');
  try {
    tracks = await fetchTracksViaAndroidVR(id);
    if (epoch !== loadEpoch) return;
    if (!tracks.length) throw new Error('未找到公开字幕轨。该视频可能没有字幕或受访问限制。');
    renderTracks();
    await loadSelectedTrack();
  } catch (error) {
    if (epoch === loadEpoch) setStatus(`字幕不可用：${error.message || error}`, 'error');
  }
}

function openVideo() {
  const url = els.videoUrl.value.trim();
  const id = videoIDFromURL(url);
  if (!id) { setStatus('请输入有效的 YouTube 视频链接。', 'error'); return; }
  els.emptyStage.classList.add('hidden');
  els.player.src = url;
  loadCaptions(id);
}

async function syncPlaybackClock() {
  if (!subtitles.length) return;
  try {
    const time = await els.player.executeJavaScript(`(() => { const video = document.querySelector('video'); return video && Number.isFinite(video.currentTime) ? video.currentTime : null; })()`);
    if (typeof time !== 'number') return;
    const next = findCue(time);
    if (next !== activeIndex) renderCue(next);
  } catch { /* WebView may still be navigating. */ }
}

function updateCredentialInputs() {
  const meta = PROVIDERS[els.settingProvider.value];
  const credential = settings.credentials[meta.storeKey] || {};
  els.settingApiKey.value = credential.apiKey || '';
  els.settingApiKey.placeholder = meta.placeholder;
  els.settingModel.value = credential.model || '';
  els.settingModel.placeholder = `默认 ${meta.defaultModel}`;
}

function openSettings() {
  els.settingProvider.replaceChildren();
  Object.keys(PROVIDERS).forEach((name) => {
    const option = document.createElement('option'); option.value = name; option.textContent = name; els.settingProvider.appendChild(option);
  });
  els.settingProvider.value = settings.provider;
  els.settingTargetLang.value = settings.targetLang;
  updateCredentialInputs();
  els.settingsDialog.showModal();
}

async function saveSettings() {
  const provider = els.settingProvider.value;
  const meta = PROVIDERS[provider];
  settings.provider = provider;
  settings.targetLang = els.settingTargetLang.value;
  settings.credentials[meta.storeKey] = { apiKey: els.settingApiKey.value.trim(), model: els.settingModel.value.trim() };
  await window.tbDesktop.setSettings(settings);
  els.settingsDialog.close();
  if (activeIndex >= 0) scheduleTranslation(activeIndex);
  setStatus('实时翻译设置已保存。');
}

async function boot() {
  settings = await window.tbDesktop.getSettings();
  settings.credentials ||= {};
  if (settings.apiKey && !Object.keys(settings.credentials).length) {
    const meta = PROVIDERS[settings.provider] || PROVIDERS['ChatGPT (OpenAI)'];
    settings.credentials[meta.storeKey] = { apiKey: settings.apiKey, model: settings.model || '' };
    await window.tbDesktop.setSettings(settings);
  }
  els.urlForm.addEventListener('submit', (event) => { event.preventDefault(); openVideo(); });
  els.trackSelect.addEventListener('change', loadSelectedTrack);
  els.btnReloadTrack.addEventListener('click', loadSelectedTrack);
  els.btnSettings.addEventListener('click', openSettings);
  els.settingProvider.addEventListener('change', updateCredentialInputs);
  els.settingsForm.addEventListener('submit', async (event) => { if (event.submitter?.value === 'cancel') return; event.preventDefault(); await saveSettings(); });
  document.getElementById('settingsSave').addEventListener('click', async (event) => { event.preventDefault(); await saveSettings(); });
  els.player.addEventListener('did-navigate', (event) => { const id = videoIDFromURL(event.url); if (id && id !== videoID) loadCaptions(id); });
  els.player.addEventListener('did-navigate-in-page', (event) => { const id = videoIDFromURL(event.url); if (id && id !== videoID) loadCaptions(id); });
  setInterval(syncPlaybackClock, 200);
}

boot();
