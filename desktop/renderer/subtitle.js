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
  const withFmt = (url, fmt) => {
    if (/[?&]fmt=[^&]*/.test(url)) {
      return url.replace(/([?&])fmt=[^&]*/, `$1fmt=${fmt}`);
    }
    return url + (url.includes('?') ? '&' : '?') + `fmt=${fmt}`;
  };
  const stripped = base
    .replace(/([?&])pot=[^&]*/g, '$1')
    .replace(/([?&])exp=[^&]*/g, '$1')
    .replace(/[?&]$/, '')
    .replace(/\?&/, '?')
    .replace(/&&+/g, '&');
  return [...new Set([
    withFmt(base, 'json3'),
    withFmt(base, '3'),
    withFmt(base, 'srv3'),
    base,
    withFmt(stripped, 'json3'),
    stripped,
  ])];
}

function normalizeTrackUrl(baseUrl) {
  return String(baseUrl || '')
    .replace(/\\u0026/g, '&')
    .replace(/\\\//g, '/');
}

function enhanceTimedtextURL(urlString) {
  try {
    const u = new URL(urlString);
    if (!u.searchParams.get('fmt')) u.searchParams.set('fmt', 'json3');
    if (!u.searchParams.get('c')) u.searchParams.set('c', 'WEB');
    return u.toString();
  } catch {
    let s = urlString;
    if (!/[?&]fmt=/.test(s)) s += (s.includes('?') ? '&' : '?') + 'fmt=json3';
    if (!/[?&]c=/.test(s)) s += '&c=WEB';
    return s;
  }
}

async function fetchBodyViaMain(urlString, headers = {}) {
  if (!window.tbDesktop?.fetchText) return null;
  try {
    const result = await window.tbDesktop.fetchText(urlString, headers);
    if (result?.ok && result.body) return result.body;
  } catch {
    // ignore
  }
  return null;
}

async function fetchBodyViaURLSession(urlString) {
  const viaMain = await fetchBodyViaMain(urlString, {
    'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    Referer: 'https://www.youtube.com',
    Origin: 'https://www.youtube.com',
  });
  if (viaMain) return viaMain;

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
  const raw = await webview.executeJavaScript(
    `(${FETCH_BODY_ASYNC_JS})(${JSON.stringify(enhanceTimedtextURL(urlString))})`,
  );
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

const INNERTUBE_CLIENTS = [
  {
    name: 'ANDROID_VR',
    ua: 'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12) gzip',
    headers: {
      'X-Youtube-Client-Name': '28',
      'X-Youtube-Client-Version': '1.65.10',
    },
    client: {
      clientName: 'ANDROID_VR',
      clientVersion: '1.65.10',
      androidSdkVersion: 32,
      osName: 'Android',
      osVersion: '12',
      hl: 'en',
      gl: 'US',
    },
  },
  {
    name: 'ANDROID',
    ua: 'com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip',
    headers: {
      'X-Youtube-Client-Name': '3',
      'X-Youtube-Client-Version': '20.10.38',
    },
    client: {
      clientName: 'ANDROID',
      clientVersion: '20.10.38',
      androidSdkVersion: 34,
      osName: 'Android',
      osVersion: '14',
      hl: 'en',
      gl: 'US',
    },
  },
  {
    name: 'IOS',
    ua: 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
    headers: {
      'X-Youtube-Client-Name': '5',
      'X-Youtube-Client-Version': '20.10.4',
    },
    client: {
      clientName: 'IOS',
      clientVersion: '20.10.4',
      deviceMake: 'Apple',
      deviceModel: 'iPhone16,2',
      osName: 'iPhone',
      osVersion: '18.3.2.22D82',
      hl: 'en',
      gl: 'US',
    },
  },
  {
    name: 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
    ua: 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version',
    headers: {},
    client: {
      clientName: 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
      clientVersion: '2.0',
      hl: 'en',
      gl: 'US',
    },
    thirdParty: { embedUrl: 'https://www.youtube.com' },
  },
];

export async function fetchTracksViaAndroidVR(videoID) {
  return fetchTracksViaInnerTube(videoID);
}

export async function fetchTracksViaInnerTube(videoID) {
  if (window.tbDesktop?.fetchInnerTubeTracks) {
    try {
      const tracks = await window.tbDesktop.fetchInnerTubeTracks(videoID);
      if (Array.isArray(tracks) && tracks.length) return tracks;
    } catch {
      // fall through
    }
  }

  for (const c of INNERTUBE_CLIENTS) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 20000);
    try {
      const res = await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': c.ua,
          ...c.headers,
        },
        body: JSON.stringify({
          context: {
            client: c.client,
            ...(c.thirdParty ? { thirdParty: c.thirdParty } : {}),
          },
          videoId: videoID,
          contentCheckOk: true,
          racyCheckOk: true,
        }),
        signal: controller.signal,
      });
      clearTimeout(timer);
      if (!res.ok) continue;
      const root = await res.json();
      const tracks = root?.captions?.playerCaptionsTracklistRenderer?.captionTracks;
      if (Array.isArray(tracks) && tracks.length) return tracks;
    } catch {
      clearTimeout(timer);
    }
  }
  return [];
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

/**
 * Capture captions via the player's own PoToken-bearing timedtext download.
 * Then re-fetch the captured URL with fmt=json3.
 */
export async function captureViaPlayer(webview, preferLang = 'en') {
  if (!webview) return [];
  try {
    const raw = await webview.executeJavaScript(
      `window.__tbRequestCaptions && window.__tbRequestCaptions(${JSON.stringify(preferLang)})`,
    );
    if (raw?.ok && raw.body) {
      const parsed = parseCaptionBody(raw.body);
      if (parsed.length) return parsed;
      // Body was captured but maybe not json3 — re-fetch with fmt=json3
      if (raw.url) {
        const body = await fetchBodyViaWebView(raw.url, webview);
        const parsed2 = parseCaptionBody(body || '');
        if (parsed2.length) return parsed2;
      }
    }
    if (raw?.lastUrl) {
      const body = await fetchBodyViaWebView(raw.lastUrl, webview);
      const parsed = parseCaptionBody(body || '');
      if (parsed.length) return parsed;
    }
  } catch {
    // ignore
  }
  return [];
}

export async function fetchSubtitlesViaTranscriptPanel(webview) {
  if (!webview) return [];
  try {
    const rows = await webview.executeJavaScript(
      'window.__tbScrapeTranscriptPanel && window.__tbScrapeTranscriptPanel()',
    );
    if (Array.isArray(rows) && rows.length) {
      return rows.map((r) => ({
        start: Number(r.start) || 0,
        duration: Math.max(Number(r.duration) || 2, 0.05),
        text: cleanCaptionText(r.text || ''),
        translation: null,
      })).filter((r) => r.text);
    }
  } catch {
    // ignore
  }
  return [];
}

/**
 * New fetch strategy:
 * 1. ANDROID_VR InnerTube first (avoids CC UI flicker)
 * 2. Player-side capture via __tbRequestCaptions (pot-bearing timedtext)
 * 3. Direct download of page track URL (last resort)
 */
export async function fetchSubtitles(track, videoID, webview, capturedBody = null) {
  // 0) If we already have a captured body from the overlay hooks, try parsing it
  if (capturedBody) {
    const parsed = parseCaptionBody(capturedBody);
    if (parsed.length) return parsed;
  }

  // 1) ANDROID_VR / InnerTube first (no CC flicker)
  if (videoID) {
    try {
      const vrTracks = await fetchTracksViaInnerTube(videoID);
      const preferred = pickTrack(vrTracks, track?.languageCode) || vrTracks[0];
      if (preferred) {
        const vrSubs = await downloadTrack(preferred, webview);
        if (vrSubs.length) return vrSubs;
      }
    } catch {
      // continue
    }
  }

  // 2) Player-side capture via __tbRequestCaptions
  const captured = await captureViaPlayer(webview, track?.languageCode || 'en');
  if (captured.length) return captured;

  // 3) Direct download of page track URL (last resort, often empty with PoToken)
  if (track?.baseUrl) {
    const pageSubs = await downloadTrack(track, webview);
    if (pageSubs.length) return pageSubs;
  }

  // 4) Scrape transcript panel as final fallback
  const panelSubs = await fetchSubtitlesViaTranscriptPanel(webview);
  if (panelSubs.length) return panelSubs;

  return [];
}
