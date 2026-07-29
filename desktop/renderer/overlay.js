/**
 * Injected into YouTube pages: bilingual caption overlay + SPA navigation hooks.
 */
export const BILINGUAL_OVERLAY_JS = `
(function() {
  if (window.__tbInstalled && window.__tbForceCaptionLoad) return;
  window.__tbInstalled = true;
  window.__tbSubs = window.__tbSubs || [];

  function post(name, payload) {
    try {
      if (window.__tbPost) window.__tbPost(name, payload);
      else if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name]) {
        window.webkit.messageHandlers[name].postMessage(payload);
      }
    } catch (e) {}
  }

  function notifyURL() { post('tbUrlChanged', location.href); }
  ['yt-navigate-finish', 'yt-page-data-updated', 'yt-navigate-start'].forEach(function(evt) {
    window.addEventListener(evt, notifyURL, true);
    document.addEventListener(evt, notifyURL, true);
  });
  window.addEventListener('popstate', notifyURL);
  var _ps = history.pushState;
  history.pushState = function() { var r = _ps.apply(this, arguments); setTimeout(notifyURL, 0); return r; };
  var _rs = history.replaceState;
  history.replaceState = function() { var r = _rs.apply(this, arguments); setTimeout(notifyURL, 0); return r; };

  var style = document.createElement('style');
  style.textContent = [
    '.ytp-caption-window-container{display:none !important;}',
    '#tb-bilingual-caption{position:absolute;left:50%;bottom:9%;transform:translateX(-50%);',
    'max-width:min(92%,720px);z-index:2147483647;pointer-events:none;text-align:center;',
    'font-family:Segoe UI,system-ui,-apple-system,sans-serif;}',
    '#tb-caption-orig{color:rgba(255,255,255,0.82);font-size:clamp(12px,2.1vw,15px);',
    'line-height:1.35;text-shadow:0 1px 3px rgba(0,0,0,0.95);margin-bottom:4px;white-space:pre-wrap;}',
    '#tb-caption-trans{color:#fff;font-size:clamp(16px,3vw,22px);font-weight:600;line-height:1.35;',
    'text-shadow:0 1px 4px rgba(0,0,0,0.95);background:rgba(0,0,0,0.45);border-radius:8px;',
    'padding:5px 12px;display:none;white-space:pre-wrap;}'
  ].join('');
  (document.documentElement || document.head || document.body).appendChild(style);

  function findPlayerContainer() {
    return document.getElementById('movie_player')
      || document.querySelector('.html5-video-player')
      || document.querySelector('#player')
      || document.querySelector('ytd-player');
  }
  function findVideo(container) {
    return (container && container.querySelector('video')) || document.querySelector('video');
  }
  function ensureOverlay() {
    var container = findPlayerContainer();
    if (!container) return null;
    var host = container.classList && container.classList.contains('html5-video-player')
      ? container
      : (container.querySelector('.html5-video-player') || container);
    var el = document.getElementById('tb-bilingual-caption');
    if (el && el.parentElement === host) return el;
    if (el) el.remove();
    el = document.createElement('div');
    el.id = 'tb-bilingual-caption';
    el.style.display = 'none';
    var orig = document.createElement('div');
    orig.id = 'tb-caption-orig';
    var trans = document.createElement('div');
    trans.id = 'tb-caption-trans';
    el.appendChild(orig);
    el.appendChild(trans);
    if (getComputedStyle(host).position === 'static') host.style.position = 'relative';
    host.appendChild(el);
    return el;
  }
  function findCue(t) {
    var subs = window.__tbSubs;
    var best = -1;
    for (var i = 0; i < subs.length; i++) {
      var s = subs[i];
      var end = s.s + Math.max(s.d || 0, 0.05);
      if (t >= s.s && t <= end + 0.15) return i;
      if (t >= s.s) best = i;
      if (s.s > t) break;
    }
    if (best >= 0) {
      var b = subs[best];
      var bEnd = b.s + Math.max(b.d || 0, 0.8);
      if (t <= bEnd + 0.35) return best;
    }
    return -1;
  }
  var lastIndex = -2;
  function tick() {
    var container = findPlayerContainer();
    var video = findVideo(container);
    var overlay = ensureOverlay();
    if (!video || !overlay) return;
    var idx = window.__tbSubs.length ? findCue(video.currentTime) : -1;
    if (idx === lastIndex) return;
    lastIndex = idx;
    var origEl = overlay.querySelector('#tb-caption-orig');
    var transEl = overlay.querySelector('#tb-caption-trans');
    if (idx < 0) {
      overlay.style.display = 'none';
    } else {
      var s = window.__tbSubs[idx];
      origEl.textContent = s.o || '';
      if (s.t) { transEl.textContent = s.t; transEl.style.display = 'inline-block'; }
      else { transEl.textContent = ''; transEl.style.display = 'none'; }
      overlay.style.display = (s.o || s.t) ? 'block' : 'none';
    }
    post('tbActiveIndex', idx);
  }
  document.addEventListener('timeupdate', function(e) {
    if (e.target && e.target.tagName === 'VIDEO') tick();
  }, true);
  document.addEventListener('seeked', function(e) {
    if (e.target && e.target.tagName === 'VIDEO') { lastIndex = -2; tick(); }
  }, true);
  setInterval(tick, 250);

  window.__tbSetSubtitles = function(subs) {
    window.__tbSubs = Array.isArray(subs) ? subs : [];
    lastIndex = -2;
    tick();
  };
  window.__tbClearSubtitles = function() {
    window.__tbSubs = [];
    lastIndex = -2;
    var overlay = document.getElementById('tb-bilingual-caption');
    if (overlay) overlay.style.display = 'none';
  };

  // ---- PoToken workaround: intercept the player's own timedtext fetches ----
  // YouTube's WEB caption URLs often include exp=xpe and need a BotGuard PoToken.
  // Direct fetches return HTTP 200 with an empty body. The real player mints pot
  // and downloads captions itself — we capture that response.
  window.__tbCapturedCaptions = null;
  window.__tbLastTimedtextUrl = null;

  function maybeCapture(url, body) {
    try {
      if (!url || !/\\/api\\/timedtext/i.test(String(url))) return;
      window.__tbLastTimedtextUrl = String(url);
      if (!body || !String(body).trim()) return;
      window.__tbCapturedCaptions = {
        url: String(url),
        body: String(body),
        at: Date.now(),
      };
    } catch (e) {}
  }

  if (!window.__tbFetchPatched) {
    window.__tbFetchPatched = true;
    var origFetch = window.fetch;
    window.fetch = function() {
      var args = arguments;
      var input = args[0];
      var url = typeof input === 'string' ? input : (input && input.url);
      return origFetch.apply(this, args).then(function(res) {
        try {
          if (url && /\\/api\\/timedtext/i.test(String(url))) {
            res.clone().text().then(function(t) { maybeCapture(url, t); }).catch(function() {});
          }
        } catch (e) {}
        return res;
      });
    };

    var OrigXHR = window.XMLHttpRequest;
    function PatchedXHR() {
      var xhr = new OrigXHR();
      var _url = '';
      var _open = xhr.open;
      xhr.open = function(method, url) {
        _url = url;
        return _open.apply(xhr, arguments);
      };
      xhr.addEventListener('load', function() {
        try {
          if (_url && /\\/api\\/timedtext/i.test(String(_url))) {
            maybeCapture(_url, xhr.responseText);
          }
        } catch (e) {}
      });
      return xhr;
    }
    PatchedXHR.prototype = OrigXHR.prototype;
    window.XMLHttpRequest = PatchedXHR;
  }

  function sleep(ms) {
    return new Promise(function(resolve) { setTimeout(resolve, ms); });
  }

  function pickPlayerTrack(preferLang) {
    var player = findPlayerContainer();
    var host = player && (player.querySelector && player.querySelector('.html5-video-player') || player);
    if (!host || typeof host.getOption !== 'function') return null;
    var list = [];
    try { list = host.getOption('captions', 'tracklist') || []; } catch (e) {}
    if (!list.length) return null;
    var prefer = String(preferLang || 'en').slice(0, 2);
    return list.find(function(t) {
      return String(t.languageCode || '').startsWith(prefer) && t.kind !== 'asr';
    }) || list.find(function(t) {
      return String(t.languageCode || '').startsWith('en') && t.kind !== 'asr';
    }) || list.find(function(t) {
      return String(t.languageCode || '').startsWith('en');
    }) || list[0];
  }

  window.__tbForceCaptionLoad = async function(preferLang) {
    window.__tbCapturedCaptions = null;
    var player = findPlayerContainer();
    var host = player && ((player.classList && player.classList.contains('html5-video-player'))
      ? player
      : (player && player.querySelector && player.querySelector('.html5-video-player')) || player);
    if (!host) return { ok: false, reason: 'no-player' };

    try { if (typeof host.loadModule === 'function') host.loadModule('captions'); } catch (e) {}
    try { if (typeof host.setOption === 'function') host.setOption('captions', 'reload', true); } catch (e) {}

    var track = pickPlayerTrack(preferLang);
    if (track && typeof host.setOption === 'function') {
      try { host.setOption('captions', 'track', track); } catch (e) {}
    } else {
      var cc = document.querySelector('.ytp-subtitles-button');
      if (cc && cc.getAttribute('aria-pressed') !== 'true') {
        try { cc.click(); } catch (e) {}
      }
    }

    var deadline = Date.now() + 9000;
    while (Date.now() < deadline) {
      if (window.__tbCapturedCaptions && window.__tbCapturedCaptions.body) {
        return {
          ok: true,
          body: window.__tbCapturedCaptions.body,
          url: window.__tbCapturedCaptions.url,
        };
      }
      await sleep(200);
    }
    return {
      ok: false,
      reason: 'timeout',
      lastUrl: window.__tbLastTimedtextUrl || null,
    };
  };

  window.__tbScrapeTranscriptPanel = async function() {
    function findTranscriptButton() {
      var nodes = document.querySelectorAll('button, yt-button-shape button, a');
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i];
        var label = ((el.getAttribute('aria-label') || '') + ' ' + (el.textContent || '')).toLowerCase();
        if (/show transcript|transcript|显示文字稿|打开文字稿|文字稿|字幕/.test(label)
            && /transcript|文字稿/.test(label)) {
          return el;
        }
      }
      return document.querySelector('button[aria-label*="transcript" i], button[aria-label*="文字稿"]');
    }

    var btn = findTranscriptButton();
    if (btn) {
      try { btn.click(); } catch (e) {}
      await sleep(1200);
    }

    var segments = document.querySelectorAll(
      'ytd-transcript-segment-renderer, ytd-transcript-body-renderer ytd-transcript-segment-renderer'
    );
    if (!segments.length) {
      // Expand description "show more" then retry once.
      var more = document.querySelector('tp-yt-paper-button#expand, #expand');
      if (more) {
        try { more.click(); } catch (e) {}
        await sleep(600);
        btn = findTranscriptButton();
        if (btn) {
          try { btn.click(); } catch (e) {}
          await sleep(1200);
        }
        segments = document.querySelectorAll('ytd-transcript-segment-renderer');
      }
    }

    var out = [];
    for (var i = 0; i < segments.length; i++) {
      var seg = segments[i];
      var textEl = seg.querySelector('.segment-text, yt-formatted-string.segment-text');
      var timeEl = seg.querySelector('.segment-timestamp, div.segment-timestamp');
      var text = ((textEl && textEl.textContent) || seg.textContent || '').replace(/\\s+/g, ' ').trim();
      if (!text) continue;
      var ts = ((timeEl && timeEl.textContent) || '').trim();
      var start = 0;
      var parts = ts.split(':').map(Number);
      if (parts.length === 3) start = parts[0] * 3600 + parts[1] * 60 + parts[2];
      else if (parts.length === 2) start = parts[0] * 60 + parts[1];
      out.push({ start: start, duration: 2, text: text, translation: null });
    }
    for (var j = 0; j < out.length - 1; j++) {
      out[j].duration = Math.max(out[j + 1].start - out[j].start, 0.05);
    }
    return out;
  };
})();
`;

export const CAPTION_TRACKS_JS = `
(function() {
  function fromPlayer(el) {
    try {
      if (el && typeof el.getPlayerResponse === 'function') {
        var r = el.getPlayerResponse();
        if (r && r.captions) return r;
      }
    } catch (e) {}
    return null;
  }
  function liveResponse() {
    var ids = ['movie_player', 'ytd-player', 'player'];
    for (var i = 0; i < ids.length; i++) {
      var el = document.getElementById(ids[i]);
      var r = fromPlayer(el);
      if (r) return r;
      if (el) {
        var nested = el.querySelector && el.querySelector('.html5-video-player');
        r = fromPlayer(nested);
        if (r) return r;
      }
    }
    var players = document.querySelectorAll('.html5-video-player');
    for (var j = 0; j < players.length; j++) {
      var pr = fromPlayer(players[j]);
      if (pr) return pr;
    }
    return null;
  }
  var pr = liveResponse();
  if (!pr) {
    pr = window.ytInitialPlayerResponse;
    if ((!pr || !pr.captions) && window.ytplayer && ytplayer.config && ytplayer.config.args && ytplayer.config.args.player_response) {
      try { pr = JSON.parse(ytplayer.config.args.player_response); } catch (e) {}
    }
  }
  var tracks = pr && pr.captions && pr.captions.playerCaptionsTracklistRenderer && pr.captions.playerCaptionsTracklistRenderer.captionTracks;
  return tracks ? JSON.stringify(tracks) : "[]";
})()
`;

export const FETCH_BODY_ASYNC_JS = `
(async function(url) {
  try {
    const res = await fetch(url, { credentials: 'include', cache: 'no-store' });
    if (!res.ok) return JSON.stringify({ ok: false, status: res.status, body: '' });
    const body = await res.text();
    return JSON.stringify({ ok: true, status: res.status, body: body });
  } catch (e) {
    return JSON.stringify({ ok: false, status: -1, body: String(e) });
  }
})
`;
