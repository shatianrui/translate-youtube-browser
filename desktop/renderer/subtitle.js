import { FETCH_BODY_ASYNC_JS } from './overlay.js';

export function cleanCaptionText(raw) {
  let s = String(raw || '');
  s = s.replace(/<br\s*\/?>/gi, '\n');
  s = s.replace(/<[^>]+>/g, '');
  const entities = [
    ['&amp;', '&'], ['&lt;', '<'], ['&gt;', '>'], ['&quot;', '"'],
    ['&#39;', "'"], ['&apos;', "'"], ['&nbsp;', ' '], ['\u00a0', ' '],
  ];
  for (const [from, to] of entities) s = s.split(from).join(to);
  s = s.replace(/&#(\d+);/g, (_, n) => {
    const code = Number(n);
    return Number.isFinite(code) ? String.fromCodePoint(code) : _;
  });
  return s.replace(/\s+/g, ' ').trim();
}

function mergeAdjacentDuplicates(subs) {
  if (!subs.length) return [];
  const out = [];
  for (const sub of subs) {
    const last = out[out.length - 1];
    if (last && last.text === sub.text && sub.start <= last.start + last.duration + 0.2) {
      const end = Math.max(last.start + last.duration, sub.start + sub.duration);
      out[out.length - 1] = { ...last, duration: end - last.start };
    } else {
      out.push({ ...sub });
    }
  }
  return out;
}

function parseJSON3(text) {
  let root;
  try {
    root = JSON.parse(text);
  } catch {
    return [];
  }
  const events = root && root.events;
  if (!Array.isArray(events)) return [];
  const raw = [];
  for (const event of events) {
    const segs = event.segs;
    if (!Array.isArray(segs)) continue;
    const startMs = Number(event.tStartMs ?? 0);
    const durMs = event.dDurationMs == null ? -1 : Number(event.dDurationMs);
    const joined = segs.map((s) => s.utf8 || '').join('');
    const cleaned = cleanCaptionText(joined);
    if (!cleaned) continue;
    raw.push({
      start: startMs / 1000,
      duration: durMs >= 0 ? durMs / 1000 : -1,
      text: cleaned,
    });
  }
  const subs = raw.map((item, i) => {
    let duration = item.duration;
    if (duration < 0) {
      duration = i + 1 < raw.length
        ? Math.max(raw[i + 1].start - item.start, 0.05)
        : 2.0;
    }
    return { start: item.start, duration: Math.max(duration, 0.05), text: item.text, translation: null };
  });
  return mergeAdjacentDuplicates(subs);
}

function parseClock(value) {
  const plain = Number(value);
  if (Number.isFinite(plain)) return plain;
  const parts = String(value).split(':');
  if (parts.length === 3) {
    return (Number(parts[0]) || 0) * 3600 + (Number(parts[1]) || 0) * 60 + (Number(parts[2]) || 0);
  }
  if (parts.length === 2) {
    return (Number(parts[0]) || 0) * 60 + (Number(parts[1]) || 0);
  }
  return 0;
}

function parseTimedTextXML(body) {
  const subs = [];
  const re = /<(?:text|p)\b([^>]*)>([\s\S]*?)<\/(?:text|p)>/gi;
  let match;
  while ((match = re.exec(body))) {
    const attrs = match[1] || '';
    const content = match[2] || '';
    const get = (name) => {
      const m = attrs.match(new RegExp(`${name}="([^"]*)"`, 'i'));
      return m ? m[1] : null;
    };
    let start = 0;
    let dur = 0;
    if (get('start') != null) start = parseClock(get('start'));
    else if (get('begin') != null) start = parseClock(get('begin'));
    if (get('dur') != null) dur = parseClock(get('dur'));
    else if (get('end') != null) dur = Math.max(parseClock(get('end')) - start, 0);
    const cleaned = cleanCaptionText(content);
    if (cleaned) {
      subs.push({ start, duration: Math.max(dur, 0.05), text: cleaned, translation: null });
    }
  }
  return subs;
}

export function parseCaptionBody(body) {
  const trimmed = String(body || '').trim();
  if (!trimmed) return [];
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    const jsonSubs = parseJSON3(trimmed);
    if (jsonSubs.length) return jsonSubs;
  }
  return parseTimedTextXML(trimmed);
}

function captionURLCandidates(base) {
  const withFmt = (fmt) => {
    if (/[?&]fmt=[^&]*/.test(base)) {
      return base.replace(/([?&])fmt=[^&]*/, `$1fmt=${fmt}`);
    }
    return base + (base.includes('?') ? '&' : '?') + `fmt=${fmt}`;
  };
  return [...new Set([withFmt('json3'), withFmt('3'), withFmt('srv3'), base])];
}

function normalizeTrackUrl(baseUrl) {
  return String(baseUrl || '')
    .replace(/\\u0026/g, '&')
    .replace(/\\\//g, '/');
}

async function fetchBodyViaURLSession(urlString) {
  const res = await fetch(urlString, {
    headers: {
      'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      Referer: 'https://www.youtube.com',
      Origin: 'https://www.youtube.com',
    },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return await res.text();
}

async function fetchBodyViaWebView(urlString, webview) {
  if (!webview) return null;
  const raw = await webview.executeJavaScript(`(${FETCH_BODY_ASYNC_JS})(${JSON.stringify(urlString)})`);
  if (typeof raw !== 'string') return null;
  try {
    const result = JSON.parse(raw);
    if (result.ok && result.body) return result.body;
  } catch {
    // ignore
  }
  return null;
}

async function downloadTrack(track, webview) {
  const base = normalizeTrackUrl(track.baseUrl);
  const candidates = captionURLCandidates(base);
  let lastError = null;
  for (const urlString of candidates) {
    try {
      let body = await fetchBodyViaWebView(urlString, webview);
      if (!body) body = await fetchBodyViaURLSession(urlString);
      const parsed = parseCaptionBody(body);
      if (parsed.length) return parsed;
    } catch (err) {
      lastError = err;
    }
  }
  if (lastError) throw lastError;
  return [];
}

export async function fetchTracksViaAndroidVR(videoID) {
  const endpoint = 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'User-Agent': 'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12) gzip',
      'X-Youtube-Client-Name': '28',
      'X-Youtube-Client-Version': '1.60.19',
    },
    body: JSON.stringify({
      context: {
        client: {
          clientName: 'ANDROID_VR',
          clientVersion: '1.60.19',
          hl: 'en',
          gl: 'US',
          androidSdkVersion: 34,
          osName: 'Android',
          osVersion: '12',
        },
      },
      videoId: videoID,
      contentCheckOk: true,
      racyCheckOk: true,
    }),
  });
  if (!res.ok) throw new Error(`InnerTube HTTP ${res.status}`);
  const root = await res.json();
  const tracks = root?.captions?.playerCaptionsTracklistRenderer?.captionTracks;
  return Array.isArray(tracks) ? tracks : [];
}

function pickTrack(tracks, preferring) {
  const languageCode = preferring || '';
  const exact = tracks.find((t) => t.languageCode === languageCode && t.kind !== 'asr');
  if (exact) return exact;
  const lang = tracks.find(
    (t) => String(t.languageCode || '').startsWith(languageCode.slice(0, 2)) && t.kind !== 'asr',
  );
  if (lang) return lang;
  const en = tracks.find((t) => String(t.languageCode || '').startsWith('en') && t.kind !== 'asr');
  if (en) return en;
  return tracks.find((t) => t.kind !== 'asr') || tracks[0] || null;
}

export async function fetchSubtitles(track, videoID, webview) {
  const pageSubs = await downloadTrack(track, webview);
  if (pageSubs.length) return pageSubs;

  if (videoID) {
    const vrTracks = await fetchTracksViaAndroidVR(videoID);
    const preferred = pickTrack(vrTracks, track.languageCode) || vrTracks[0];
    if (preferred) {
      const vrSubs = await downloadTrack(preferred, null);
      if (vrSubs.length) return vrSubs;
    }
    for (const t of vrTracks) {
      const subs = await downloadTrack(t, null);
      if (subs.length) return subs;
    }
  }
  return [];
}
