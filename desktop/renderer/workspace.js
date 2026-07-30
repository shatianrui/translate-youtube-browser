import { fetchSubtitles, fetchTracksViaAndroidVR } from './subtitle.js';
import { PROVIDERS, translateTexts } from './translation.js';

const els = {
  videoUrl: document.getElementById('videoUrl'),
  btnFetch: document.getElementById('btnFetch'),
  status: document.getElementById('status'),
  trackSelect: document.getElementById('trackSelect'),
  btnLoadTrack: document.getElementById('btnLoadTrack'),
  btnTranslate: document.getElementById('btnTranslate'),
  btnExportSrt: document.getElementById('btnExportSrt'),
  btnExportTxt: document.getElementById('btnExportTxt'),
  count: document.getElementById('count'),
  subtitleList: document.getElementById('subtitleList'),
  btnSettings: document.getElementById('btnSettings'),
  settingsDialog: document.getElementById('settingsDialog'),
  settingsForm: document.getElementById('settingsForm'),
  settingProvider: document.getElementById('settingProvider'),
  settingApiKey: document.getElementById('settingApiKey'),
  settingModel: document.getElementById('settingModel'),
  settingTargetLang: document.getElementById('settingTargetLang'),
};

let tracks = [];
let subtitles = [];
let settings = { provider: 'ChatGPT (OpenAI)', targetLang: '中文', credentials: {} };

function setStatus(message, kind = '') {
  els.status.textContent = message;
  els.status.className = `status ${kind}`;
}

function videoIDFromURL(raw) {
  try {
    const url = new URL(raw.trim());
    const host = url.hostname.toLowerCase();
    const valid = (id) => /^[A-Za-z0-9_-]{10,12}$/.test(id || '') ? id : null;
    if (host.includes('youtu.be')) return valid(url.pathname.split('/').filter(Boolean)[0]);
    const parts = url.pathname.split('/').filter(Boolean);
    if (['shorts', 'embed', 'live', 'v'].includes(parts[0])) return valid(parts[1]);
    return valid(url.searchParams.get('v'));
  } catch {
    return null;
  }
}

function currentCredential() {
  const meta = PROVIDERS[settings.provider] || PROVIDERS['ChatGPT (OpenAI)'];
  return settings.credentials[meta.storeKey] || {};
}

function setBusy(busy) {
  for (const el of [els.btnFetch, els.btnLoadTrack, els.btnTranslate]) el.disabled = busy || el.disabled;
}

function renderTracks() {
  els.trackSelect.replaceChildren();
  tracks.forEach((track, index) => {
    const option = document.createElement('option');
    option.value = String(index);
    const label = track.name?.simpleText || track.name?.runs?.map((run) => run.text).join('') || track.languageCode || 'Unknown';
    option.textContent = `${label} (${track.languageCode || '?'})${track.kind === 'asr' ? ' · 自动生成' : ''}`;
    els.trackSelect.appendChild(option);
  });
  els.trackSelect.disabled = !tracks.length;
  els.btnLoadTrack.disabled = !tracks.length;
}

function formatTime(seconds) {
  const value = Math.max(0, Number(seconds) || 0);
  const hours = Math.floor(value / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  const whole = Math.floor(value % 60);
  const milliseconds = Math.round((value - Math.floor(value)) * 1000);
  const prefix = hours ? `${String(hours).padStart(2, '0')}:` : '';
  return `${prefix}${String(minutes).padStart(2, '0')}:${String(whole).padStart(2, '0')}`;
}

function renderSubtitles() {
  els.count.textContent = `${subtitles.length} 条字幕`;
  els.subtitleList.replaceChildren();
  if (!subtitles.length) {
    const empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = '未载入字幕。';
    els.subtitleList.appendChild(empty);
    return;
  }
  const fragment = document.createDocumentFragment();
  subtitles.forEach((subtitle) => {
    const cue = document.createElement('article');
    cue.className = 'cue';
    const time = document.createElement('div');
    time.className = 'time';
    time.textContent = formatTime(subtitle.start);
    const body = document.createElement('div');
    const original = document.createElement('div');
    original.className = 'original';
    original.textContent = subtitle.text;
    const translation = document.createElement('div');
    translation.className = 'translation';
    translation.textContent = subtitle.translation || '';
    body.append(original, translation);
    cue.append(time, body);
    fragment.appendChild(cue);
  });
  els.subtitleList.appendChild(fragment);
}

function updateActions() {
  const hasSubtitles = subtitles.length > 0;
  els.btnTranslate.disabled = !hasSubtitles;
  els.btnExportSrt.disabled = !hasSubtitles;
  els.btnExportTxt.disabled = !hasSubtitles;
}

async function fetchTracks() {
  const videoID = videoIDFromURL(els.videoUrl.value);
  if (!videoID) {
    setStatus('请输入有效的 YouTube 视频链接。', 'error');
    return;
  }
  els.btnFetch.disabled = true;
  tracks = [];
  subtitles = [];
  renderTracks();
  renderSubtitles();
  updateActions();
  setStatus('正在获取可用字幕轨…', 'busy');
  try {
    tracks = await fetchTracksViaAndroidVR(videoID);
    if (!tracks.length) throw new Error('未找到公开字幕轨。视频可能没有字幕或被 YouTube 限制。');
    renderTracks();
    setStatus(`已发现 ${tracks.length} 条字幕轨。选择后载入。`);
  } catch (error) {
    setStatus(`获取失败：${error.message || error}`, 'error');
  } finally {
    els.btnFetch.disabled = false;
  }
}

async function loadTrack() {
  const videoID = videoIDFromURL(els.videoUrl.value);
  const track = tracks[Number(els.trackSelect.value)];
  if (!videoID || !track) return;
  els.btnLoadTrack.disabled = true;
  setStatus('正在下载并解析字幕…', 'busy');
  try {
    subtitles = await fetchSubtitles(track, videoID, null);
    if (!subtitles.length) throw new Error('字幕内容为空。请更换字幕轨后重试。');
    renderSubtitles();
    updateActions();
    setStatus(`已载入 ${subtitles.length} 条 ${track.languageCode || ''} 字幕。`);
  } catch (error) {
    setStatus(`载入失败：${error.message || error}`, 'error');
  } finally {
    els.btnLoadTrack.disabled = false;
  }
}

async function translateAll() {
  const credential = currentCredential();
  if (!credential.apiKey) {
    setStatus(`请先填写 ${settings.provider} API Key。`, 'error');
    openSettings();
    return;
  }
  els.btnTranslate.disabled = true;
  try {
    for (let start = 0; start < subtitles.length; start += 20) {
      const end = Math.min(start + 20, subtitles.length);
      setStatus(`正在翻译 ${end}/${subtitles.length}…`, 'busy');
      const translated = await translateTexts({
        provider: settings.provider,
        apiKey: credential.apiKey,
        model: credential.model || '',
        texts: subtitles.slice(start, end).map((subtitle) => subtitle.text),
        targetLang: settings.targetLang,
      });
      for (let i = start; i < end; i += 1) subtitles[i].translation = translated[i - start] || '';
      renderSubtitles();
    }
    setStatus(`翻译完成（${settings.provider}）。`);
  } catch (error) {
    setStatus(`翻译失败：${error.message || error}`, 'error');
  } finally {
    els.btnTranslate.disabled = false;
  }
}

function srtTimestamp(seconds) {
  const value = Math.max(0, Number(seconds) || 0);
  const hours = Math.floor(value / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  const whole = Math.floor(value % 60);
  const milliseconds = Math.round((value - Math.floor(value)) * 1000);
  return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(whole).padStart(2, '0')},${String(milliseconds).padStart(3, '0')}`;
}

async function exportSubtitles(kind) {
  const hasTranslation = subtitles.some((subtitle) => subtitle.translation);
  const content = kind === 'srt'
    ? subtitles.map((subtitle, index) => `${index + 1}\n${srtTimestamp(subtitle.start)} --> ${srtTimestamp(subtitle.start + subtitle.duration)}\n${subtitle.text}${subtitle.translation ? `\n${subtitle.translation}` : ''}`).join('\n\n')
    : subtitles.map((subtitle) => `[${formatTime(subtitle.start)}]\n${subtitle.text}${subtitle.translation ? `\n${subtitle.translation}` : ''}`).join('\n\n');
  const saved = await window.tbDesktop.saveSubtitles({
    content: `${content}\n`,
    defaultPath: `youtube-${hasTranslation ? 'bilingual-' : ''}subtitles.${kind}`,
  });
  setStatus(saved ? '文件已导出。' : '已取消导出。');
}

function openSettings() {
  els.settingProvider.replaceChildren();
  Object.keys(PROVIDERS).forEach((name) => {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    els.settingProvider.appendChild(option);
  });
  els.settingProvider.value = settings.provider;
  updateCredentialInputs();
  els.settingTargetLang.value = settings.targetLang;
  els.settingsDialog.showModal();
}

function updateCredentialInputs() {
  const meta = PROVIDERS[els.settingProvider.value];
  const credential = settings.credentials[meta.storeKey] || {};
  els.settingApiKey.value = credential.apiKey || '';
  els.settingApiKey.placeholder = meta.placeholder;
  els.settingModel.value = credential.model || '';
  els.settingModel.placeholder = `默认 ${meta.defaultModel}`;
}

async function saveSettings() {
  const provider = els.settingProvider.value;
  const meta = PROVIDERS[provider];
  settings.provider = provider;
  settings.targetLang = els.settingTargetLang.value;
  settings.credentials[meta.storeKey] = {
    apiKey: els.settingApiKey.value.trim(),
    model: els.settingModel.value.trim(),
  };
  await window.tbDesktop.setSettings(settings);
  els.settingsDialog.close();
  setStatus('翻译设置已保存。');
}

async function boot() {
  settings = await window.tbDesktop.getSettings();
  settings.credentials ||= {};
  if (settings.apiKey && !Object.keys(settings.credentials).length) {
    const meta = PROVIDERS[settings.provider] || PROVIDERS['ChatGPT (OpenAI)'];
    settings.credentials[meta.storeKey] = { apiKey: settings.apiKey, model: settings.model || '' };
    await window.tbDesktop.setSettings(settings);
  }
  els.btnFetch.addEventListener('click', fetchTracks);
  els.videoUrl.addEventListener('keydown', (event) => { if (event.key === 'Enter') fetchTracks(); });
  els.btnLoadTrack.addEventListener('click', loadTrack);
  els.btnTranslate.addEventListener('click', translateAll);
  els.btnExportSrt.addEventListener('click', () => exportSubtitles('srt'));
  els.btnExportTxt.addEventListener('click', () => exportSubtitles('txt'));
  els.btnSettings.addEventListener('click', openSettings);
  els.settingProvider.addEventListener('change', updateCredentialInputs);
  els.settingsForm.addEventListener('submit', async (event) => {
    if (event.submitter?.value === 'cancel') return;
    event.preventDefault();
    await saveSettings();
  });
  document.getElementById('settingsSave').addEventListener('click', async (event) => { event.preventDefault(); await saveSettings(); });
}

boot();
