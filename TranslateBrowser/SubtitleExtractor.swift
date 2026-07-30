import Foundation
import WebKit

enum SubtitleExtractor {
    // Prefer the live player response: YouTube is an SPA and ytInitialPlayerResponse only
    // reflects the first HTML payload, not subsequent in-page video navigations.
    static let captionTracksJS = """
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
        var ids = ['movie_player', 'shorts-player', 'ytd-player', 'player'];
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
        var activeReel = document.querySelector('ytd-reel-video-renderer[is-active] #player, ytd-reel-video-renderer[is-active] .html5-video-player');
        var rActive = fromPlayer(activeReel);
        if (rActive) return rActive;
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
    """

    /// Injected at document-start. Hooks fetch/XHR to capture the player's own timedtext
    /// responses (which already carry a valid PoToken), renders bilingual overlay inside the
    /// player DOM, and reports SPA navigations back to Swift.
    static let bilingualOverlayJS = """
    (function() {
      var host = (location.hostname || '').toLowerCase();
      if (host.indexOf('youtube.com') === -1 && host.indexOf('youtube-nocookie.com') === -1 && host.indexOf('youtu.be') === -1) {
        return;
      }
      if (window.__tbInstalled) return;
      window.__tbInstalled = true;
      window.__tbSubs = [];
      window.__tbCapturedBody = null;
      window.__tbCapturedURL = null;
      window.__tbCaptionWaiters = [];

      function post(name, payload) {
        try { window.webkit.messageHandlers[name].postMessage(payload); } catch (e) {}
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

      function isTimedtext(url) {
        return url && String(url).indexOf('/api/timedtext') !== -1;
      }
      function captureTimedtext(url, body) {
        if (!isTimedtext(url)) return;
        // Never keep ad-break caption payloads — they poison content A/V sync.
        try {
          var p = document.getElementById('movie_player')
            || document.querySelector('.html5-video-player');
          if (p && p.classList && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting'))) {
            return;
          }
          if (document.querySelector('.ad-showing, .ad-interrupting, .ytp-ad-player-overlay')) return;
        } catch (e) {}
        if (!body || body.length < 20) return;
        // Ignore empty PoToken-blocked responses
        var trimmed = String(body).replace(/^\\s+/, '');
        if (!trimmed || trimmed === '{}' || trimmed === '[]') return;
        window.__tbCapturedURL = String(url);
        window.__tbCapturedBody = String(body);
        post('tbCaptionBody', { url: String(url), body: String(body) });
        var waiters = window.__tbCaptionWaiters.splice(0);
        waiters.forEach(function(cb) { try { cb(String(body), String(url)); } catch (e) {} });
      }

      // --- Network hooks: steal the player's own pot-bearing timedtext responses ---
      try {
        var nativeFetch = window.fetch;
        window.fetch = function() {
          var args = arguments;
          var input = args[0];
          var url = (typeof input === 'string') ? input : (input && input.url);
          return nativeFetch.apply(this, args).then(function(res) {
            try {
              if (isTimedtext(url)) {
                res.clone().text().then(function(t) { captureTimedtext(url, t); }).catch(function(){});
              }
            } catch (e) {}
            return res;
          });
        };
      } catch (e) {}

      try {
        var xo = XMLHttpRequest.prototype.open;
        var xs = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url) {
          this.__tbURL = url;
          return xo.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function() {
          var xhr = this;
          if (isTimedtext(xhr.__tbURL)) {
            xhr.addEventListener('load', function() {
              try { captureTimedtext(xhr.__tbURL, xhr.responseText); } catch (e) {}
            });
          }
          return xs.apply(this, arguments);
        };
      } catch (e) {}

      function findPlayer() {
        return document.getElementById('movie_player')
          || document.getElementById('shorts-player')
          || document.querySelector('ytd-reel-video-renderer[is-active] .html5-video-player')
          || document.querySelector('.html5-video-player')
          || document.querySelector('#player');
      }

      function preferredTrack(tracks, preferLang) {
        if (!tracks || !tracks.length) return null;
        var lang = preferLang || 'en';
        for (var i = 0; i < tracks.length; i++) {
          var t = tracks[i];
          if (t.kind !== 'asr' && t.languageCode && t.languageCode.indexOf(lang) === 0) return t;
        }
        for (var j = 0; j < tracks.length; j++) {
          if (tracks[j].kind !== 'asr') return tracks[j];
        }
        return tracks[0];
      }

      function enableNativeCaptions(preferLang) {
        var player = findPlayer();
        if (!player) return false;
        try { if (player.loadModule) player.loadModule('captions'); } catch (e) {}
        var tracks = [];
        try {
          var pr = player.getPlayerResponse && player.getPlayerResponse();
          tracks = (pr && pr.captions && pr.captions.playerCaptionsTracklistRenderer
            && pr.captions.playerCaptionsTracklistRenderer.captionTracks) || [];
        } catch (e) {}
        var track = preferredTrack(tracks, preferLang);
        try {
          if (track && player.setOption) {
            player.setOption('captions', 'track', {
              languageCode: track.languageCode,
              languageName: (track.name && (track.name.simpleText || '')) || '',
              kind: track.kind || ''
            });
          } else if (player.toggleSubtitlesOn) {
            player.toggleSubtitlesOn();
          }
        } catch (e) {}
        try {
          var btn = document.querySelector('.ytp-subtitles-button, button[aria-label*="ubtitles"], button[aria-label*="字幕"]');
          if (btn && btn.getAttribute('aria-pressed') !== 'true') btn.click();
        } catch (e) {}
        return !!track || !!player;
      }

      // Keep native CC ON by default. YouTube only issues pot-bearing timedtext when CC
      // is active; our CSS already hides the native text so bilingual overlay can replace it.
      window.__tbEnsureCaptionsOn = function(preferLang) {
        return enableNativeCaptions(preferLang || 'en');
      };
      function keepCaptionsOn() {
        try { enableNativeCaptions('en'); } catch (e) {}
      }
      ['yt-navigate-finish', 'yt-page-data-updated'].forEach(function(evt) {
        window.addEventListener(evt, function() { setTimeout(keepCaptionsOn, 400); setTimeout(keepCaptionsOn, 1500); }, true);
      });
      document.addEventListener('play', function(e) {
        if (e.target && e.target.tagName === 'VIDEO') setTimeout(keepCaptionsOn, 200);
      }, true);
      setTimeout(keepCaptionsOn, 800);
      setTimeout(keepCaptionsOn, 2500);
      setTimeout(keepCaptionsOn, 5000);

      // Ask the player to load captions so its own request (with pot) hits our hooks.
      // Then optionally re-fetch the captured URL as json3 for a clean parse.
      window.__tbRequestCaptions = async function(preferLang) {
        if (window.__tbCapturedBody && window.__tbCapturedBody.length > 20) {
          return JSON.stringify({ ok: true, body: window.__tbCapturedBody, url: window.__tbCapturedURL || '' });
        }
        enableNativeCaptions(preferLang || 'en');

        var body = await new Promise(function(resolve) {
          if (window.__tbCapturedBody) { resolve(window.__tbCapturedBody); return; }
          var settled = false;
          var timer = setTimeout(function() {
            if (!settled) { settled = true; resolve(window.__tbCapturedBody); }
          }, 12000);
          window.__tbCaptionWaiters.push(function(b) {
            if (!settled) { settled = true; clearTimeout(timer); resolve(b); }
          });
          setTimeout(function() { enableNativeCaptions(preferLang || 'en'); }, 800);
          setTimeout(function() { enableNativeCaptions(preferLang || 'en'); }, 2200);
          setTimeout(function() { enableNativeCaptions(preferLang || 'en'); }, 4500);
        });

        // Keep native CC ON — turning it off was a common cause of "blocked" empty timedtext.
        enableNativeCaptions(preferLang || 'en');

        if (!body) return JSON.stringify({ ok: false, body: '', url: window.__tbCapturedURL || '', error: 'no_capture' });

        var url = window.__tbCapturedURL || '';
        if (url) {
          try {
            var u = new URL(url, location.origin);
            u.searchParams.set('fmt', 'json3');
            // Keep pot / c params from the player's URL — required to beat empty-body blocks.
            var res = await fetch(u.toString(), { credentials: 'include', cache: 'no-store' });
            if (res.ok) {
              var text = await res.text();
              if (text && text.length > 20) {
                window.__tbCapturedBody = text;
                body = text;
              }
            }
          } catch (e) {}
        }
        return JSON.stringify({ ok: true, body: body, url: url });
      };

      window.__tbClearCaptionCapture = function() {
        window.__tbCapturedBody = null;
        window.__tbCapturedURL = null;
      };

      // --- Keep playback INLINE (never hand off to iOS native fullscreen popup) ---
      function forcePlaysInline(video) {
        if (!video || video.tagName !== 'VIDEO') return;
        try {
          video.setAttribute('playsinline', '');
          video.setAttribute('webkit-playsinline', '');
          video.playsInline = true;
          // Prefer in-page presentation; never allow native fullscreen takeover.
          if ('webkitSupportsPresentationMode' in video) {
            try { video.webkitSetPresentationMode && video.webkitSetPresentationMode('inline'); } catch (e) {}
          }
        } catch (e) {}
      }
      function forceAllVideosInline(root) {
        var scope = root || document;
        var list = scope.querySelectorAll ? scope.querySelectorAll('video') : [];
        for (var i = 0; i < list.length; i++) forcePlaysInline(list[i]);
      }
      forceAllVideosInline(document);
      try {
        var mo = new MutationObserver(function(mutations) {
          for (var i = 0; i < mutations.length; i++) {
            var nodes = mutations[i].addedNodes;
            for (var j = 0; j < nodes.length; j++) {
              var n = nodes[j];
              if (!n || n.nodeType !== 1) continue;
              if (n.tagName === 'VIDEO') forcePlaysInline(n);
              else forceAllVideosInline(n);
            }
          }
        });
        mo.observe(document.documentElement || document, { childList: true, subtree: true });
      } catch (e) {}
      document.addEventListener('webkitbeginfullscreen', function(e) {
        // If iOS still tries to present the native video controller, bail out immediately.
        try {
          var v = e.target;
          if (v && v.webkitExitFullscreen) v.webkitExitFullscreen();
          enterDOMFullscreen();
        } catch (err) {}
      }, true);
      document.addEventListener('play', function(e) {
        if (e.target && e.target.tagName === 'VIDEO') forcePlaysInline(e.target);
      }, true);

      function findPlayerContainer() {
        return document.getElementById('movie_player')
          || document.getElementById('shorts-player')
          || document.querySelector('ytd-reel-video-renderer[is-active] #player')
          || document.querySelector('.html5-video-player')
          || document.querySelector('#player')
          || document.querySelector('ytd-player');
      }
      function findVideoHost() {
        var player = findPlayerContainer();
        if (!player) return null;
        // Prefer the box that actually wraps the <video> so captions sit on the picture.
        return player.querySelector('.html5-video-container')
          || (player.classList && player.classList.contains('html5-video-player') ? player : null)
          || player.querySelector('.html5-video-player')
          || player;
      }
      function findVideo(container) {
        // Prefer the main content video — never the ad slot video.
        var scope = container || document;
        return scope.querySelector('video.html5-main-video')
          || scope.querySelector('.html5-video-container video')
          || scope.querySelector('video')
          || document.querySelector('#movie_player video.html5-main-video')
          || document.querySelector('video.html5-main-video')
          || document.querySelector('video');
      }

      function isAdShowing() {
        var p = findPlayerContainer();
        if (p && p.classList && p.classList.contains('ad-showing')) {
          return true;
        }
        // Require the skip/preview overlay — bare .ytp-ad-player-overlay can linger falsely.
        return !!document.querySelector('.ad-showing .ytp-ad-player-overlay, .ad-showing.ad-interrupting');
      }

      /** Media clock used by YouTube's own CC — prefer player API over <video>.currentTime. */
      function mediaTime() {
        var p = findPlayerContainer();
        if (p) {
          try {
            if (typeof p.getCurrentTime === 'function') {
              var pt = p.getCurrentTime();
              if (typeof pt === 'number' && isFinite(pt) && pt >= 0) return pt;
            }
          } catch (e) {}
        }
        var host = findVideoHost();
        var video = findVideo(host);
        if (!video) return -1;
        var t = video.currentTime;
        return (typeof t === 'number' && isFinite(t)) ? t : -1;
      }

      function enterDOMFullscreen() {
        var host = findPlayerContainer();
        var target = host && (host.querySelector('.html5-video-player') || host);
        if (!target) return;
        try {
          if (target.requestFullscreen) target.requestFullscreen();
          else if (target.webkitRequestFullscreen) target.webkitRequestFullscreen();
        } catch (e) {}
      }

      // Hard-block native AVKit fullscreen. NEVER fall back to webkitEnterFullscreen —
      // that is exactly the "弹出播放窗口" the user does not want.
      try {
        var proto = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
        if (proto) {
          if (proto.webkitEnterFullscreen) {
            proto.webkitEnterFullscreen = function() { enterDOMFullscreen(); };
          }
          if (proto.webkitEnterFullScreen) {
            proto.webkitEnterFullScreen = function() { enterDOMFullscreen(); };
          }
        }
      } catch (e) {}

      // YouTube fullscreen button → DOM fullscreen on the player (keeps our caption node).
      document.addEventListener('click', function(e) {
        var btn = e.target && e.target.closest && e.target.closest(
          '.ytp-fullscreen-button, button.ytp-fullscreen-button, .ytp-size-button'
        );
        if (!btn) return;
        // Let theater mode (size) pass; only redirect true fullscreen.
        if (btn.classList.contains('ytp-size-button')) return;
        e.preventDefault();
        e.stopPropagation();
        var player = findPlayerContainer();
        var isFs = !!(document.fullscreenElement || document.webkitFullscreenElement);
        if (isFs) {
          try {
            if (document.exitFullscreen) document.exitFullscreen();
            else if (document.webkitExitFullscreen) document.webkitExitFullscreen();
          } catch (err) {}
        } else {
          enterDOMFullscreen();
        }
      }, true);

      // --- Bilingual captions at YouTube's native CC position (not a separate panel/sheet) ---
      var style = document.createElement('style');
      style.textContent = [
        /* Keep YouTube's caption container for layout, hide only its native text nodes. */
        '.ytp-caption-window-container .captions-text,',
        '.ytp-caption-window-container .ytp-caption-segment,',
        '.ytp-caption-window-container .caption-visual-line{opacity:0 !important;height:0 !important;',
        'overflow:hidden !important;font-size:0 !important;padding:0 !important;margin:0 !important;}',
        '.ytp-caption-window-container{pointer-events:none !important;z-index:40 !important;}',
        '#tb-caption-window{position:absolute;left:50%;bottom:8%;transform:translate(-50%,0);',
        'max-width:92%;width:max-content;text-align:center;pointer-events:none;z-index:2147483000;',
        'font-family:"YouTube Noto",Roboto,Arial,Helvetica,sans-serif;display:none;}',
        /* Keep captions readable in landscape / DOM fullscreen. */
        ':fullscreen #tb-caption-window, :-webkit-full-screen #tb-caption-window{bottom:12%;',
        'z-index:2147483000 !important;}',
        '#tb-caption-orig{color:#fff;font-size:clamp(13px,2.2vw,18px);line-height:1.35;',
        'text-shadow:0 0 2px #000,0 1px 3px rgba(0,0,0,.9);margin-bottom:2px;white-space:pre-wrap;',
        'background:rgba(8,8,8,.55);padding:2px 6px;border-radius:3px;display:inline-block;}',
        '#tb-caption-trans{color:#fff;font-size:clamp(15px,2.6vw,22px);font-weight:500;line-height:1.35;',
        'text-shadow:0 0 2px #000,0 1px 3px rgba(0,0,0,.9);white-space:pre-wrap;',
        'background:rgba(8,8,8,.65);padding:3px 8px;border-radius:3px;display:none;}'
      ].join('');
      (document.documentElement || document.head || document.body).appendChild(style);

      function ensureNativeCaptionContainer(player) {
        var container = player.querySelector('.ytp-caption-window-container');
        if (container) return container;
        container = document.createElement('div');
        container.className = 'ytp-caption-window-container';
        container.style.cssText = 'position:absolute;left:0;right:0;top:0;bottom:0;overflow:hidden;pointer-events:none;z-index:40;';
        if (getComputedStyle(player).position === 'static') player.style.position = 'relative';
        player.appendChild(container);
        return container;
      }

      function ensureOverlay() {
        var player = findPlayerContainer();
        if (!player) return null;
        var host = player.classList && player.classList.contains('html5-video-player')
          ? player
          : (player.querySelector('.html5-video-player') || player);
        var container = ensureNativeCaptionContainer(host);
        var win = document.getElementById('tb-caption-window');
        if (win && win.parentElement === container) return win;
        if (win) win.remove();
        win = document.createElement('div');
        win.id = 'tb-caption-window';
        win.className = 'ytp-caption-window ytp-caption-window-bottom ytp-caption-window-rollup';
        var orig = document.createElement('div');
        orig.id = 'tb-caption-orig';
        var trans = document.createElement('div');
        trans.id = 'tb-caption-trans';
        var wrap = document.createElement('div');
        wrap.id = 'tb-bilingual-caption';
        wrap.appendChild(orig);
        wrap.appendChild(document.createElement('br'));
        wrap.appendChild(trans);
        win.appendChild(wrap);
        container.appendChild(win);
        return win;
      }
      // Strict timing: show cue only while playhead is inside the original window
      // [s, e). No sticky linger — that was causing A/V desync after seeks / gaps.
      // Small lead compensates for paint latency so lines feel locked to speech.
      var SYNC_LEAD = 0.06;
      function findCue(t) {
        var subs = window.__tbSubs;
        if (!subs || !subs.length) return -1;
        var lo = 0, hi = subs.length - 1, cand = -1;
        while (lo <= hi) {
          var mid = (lo + hi) >> 1;
          if (subs[mid].s <= t) { cand = mid; lo = mid + 1; }
          else hi = mid - 1;
        }
        if (cand < 0) return -1;
        var cue = subs[cand];
        var end = (typeof cue.e === 'number' && cue.e > cue.s)
          ? cue.e
          : (cue.s + Math.max(cue.d || 0, 0.05));
        // If we landed past this cue (gap), stay blank — do not stick.
        if (t >= cue.s && t < end) return cand;
        // Rare overlap / abut: if next cue already started, prefer it.
        var next = cand + 1;
        if (next < subs.length && t >= subs[next].s) {
          var n = subs[next];
          var nEnd = (typeof n.e === 'number' && n.e > n.s) ? n.e : (n.s + Math.max(n.d || 0, 0.05));
          if (t < nEnd) return next;
        }
        return -1;
      }
      var lastIndex = -2;
      var lastSig = '';
      var lastInlineFix = 0;
      var cachedVideo = null;
      function cueSignature(idx) {
        if (idx < 0 || !window.__tbSubs[idx]) return '';
        var s = window.__tbSubs[idx];
        return idx + '|' + (s.o || '') + '|' + (s.t || '');
      }
      function renderCue(idx) {
        var win = ensureOverlay();
        if (!win) return;
        var origEl = win.querySelector('#tb-caption-orig');
        var transEl = win.querySelector('#tb-caption-trans');
        if (!origEl || !transEl) return;
        if (idx < 0 || !window.__tbSubs[idx]) {
          win.style.display = 'none';
          origEl.textContent = '';
          transEl.textContent = '';
          transEl.style.display = 'none';
          return;
        }
        var s = window.__tbSubs[idx];
        origEl.textContent = s.o || '';
        origEl.style.display = s.o ? 'inline-block' : 'none';
        if (s.t) {
          transEl.textContent = s.t;
          transEl.style.display = 'inline-block';
        } else {
          transEl.textContent = '';
          transEl.style.display = 'none';
        }
        win.style.display = (s.o || s.t) ? 'block' : 'none';
      }
      function tick(force) {
        var now = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
        // Inline-video fixes are unrelated to caption sync — don't do them every frame.
        if (force || now - lastInlineFix > 1500) {
          forceAllVideosInline(document);
          lastInlineFix = now;
          cachedVideo = null;
        }
        if (isAdShowing()) {
          if (lastIndex !== -1 || force) {
            lastIndex = -1;
            lastSig = '';
            renderCue(-1);
          }
          return;
        }
        var t = mediaTime();
        if (t < 0) return;
        // Lead the clock slightly so captions appear with speech (paint + decode lag).
        var idx = window.__tbSubs.length ? findCue(t + SYNC_LEAD) : -1;
        var sig = cueSignature(idx);
        if (!force && idx === lastIndex && sig === lastSig) return;
        lastIndex = idx;
        lastSig = sig;
        renderCue(idx);
        post('tbActiveIndex', idx);
      }
      function bump() { lastIndex = -2; lastSig = ''; tick(true); }
      document.addEventListener('timeupdate', function(e) {
        if (e.target && e.target.tagName === 'VIDEO') tick(false);
      }, true);
      document.addEventListener('seeked', function(e) {
        if (e.target && e.target.tagName === 'VIDEO') bump();
      }, true);
      document.addEventListener('seeking', function(e) {
        if (e.target && e.target.tagName === 'VIDEO') bump();
      }, true);
      document.addEventListener('ratechange', function(e) {
        if (e.target && e.target.tagName === 'VIDEO') bump();
      }, true);
      document.addEventListener('play', function(e) {
        if (e.target && e.target.tagName === 'VIDEO') tick(false);
      }, true);
      document.addEventListener('pause', function(e) {
        if (e.target && e.target.tagName === 'VIDEO') tick(true);
      }, true);
      document.addEventListener('fullscreenchange', bump);
      document.addEventListener('webkitfullscreenchange', bump);
      // Landscape / rotate: YouTube rebuilds player chrome — reattach overlay + keep translating.
      window.__tbReattachOverlay = function() {
        try {
          lastIndex = -2;
          lastSig = '';
          ensureOverlay();
          tick(true);
        } catch (e) {}
      };
      window.addEventListener('orientationchange', function() {
        setTimeout(window.__tbReattachOverlay, 50);
        setTimeout(window.__tbReattachOverlay, 350);
        setTimeout(window.__tbReattachOverlay, 900);
      });
      window.addEventListener('resize', function() {
        setTimeout(window.__tbReattachOverlay, 80);
      });
      try {
        if (window.visualViewport) {
          window.visualViewport.addEventListener('resize', function() {
            setTimeout(window.__tbReattachOverlay, 80);
          });
        }
      } catch (e) {}
      // rAF: sample the player clock every frame while playing for tight A/V lock.
      (function rafLoop() {
        try { tick(false); } catch (e) {}
        requestAnimationFrame(rafLoop);
      })();

      window.__tbSetSubtitles = function(subs) {
        var list = Array.isArray(subs) ? subs : [];
        // Normalize end times client-side too (clip to next start) in case an older
        // payload still sends only {s,d}. Never extend past the next cue.
        for (var i = 0; i < list.length; i++) {
          var cue = list[i];
          var nextStart = (i + 1 < list.length) ? list[i + 1].s : null;
          var rawEnd = (typeof cue.e === 'number' && cue.e > cue.s)
            ? cue.e
            : (cue.s + Math.max(cue.d || 0, 0.05));
          if (nextStart != null && isFinite(nextStart)) {
            cue.e = Math.min(rawEnd, nextStart);
          } else {
            cue.e = rawEnd;
          }
          if (!(cue.e > cue.s)) cue.e = cue.s + 0.05;
        }
        window.__tbSubs = list;
        bump();
      };
      window.__tbClearSubtitles = function() {
        window.__tbSubs = [];
        lastIndex = -2;
        lastSig = '';
        renderCue(-1);
      };
    })();
    """

    /// Body for callAsyncJavaScript — awaits the page-side caption capture (with PoToken).
    static let requestCaptionsAsyncJS = """
    if (typeof window.__tbRequestCaptions !== 'function') {
      return JSON.stringify({ ok: false, body: '', url: '', error: 'not_installed' });
    }
    return await window.__tbRequestCaptions(preferLang || 'en');
    """

    struct CaptureResult: Decodable {
        let ok: Bool
        let body: String
        let url: String?
        let error: String?
    }

    /// Beat YouTube empty-body blocks.
    /// Prefer ANDROID/IOS InnerTube signed timedtext (no WEB PoToken), then player capture.
    static func fetchSubtitles(
        from track: CaptionTrack,
        videoID: String?,
        using webView: WKWebView?
    ) async throws -> [Subtitle] {
        // 1) InnerTube ANDROID/IOS first — most reliable in 2025/2026 (no WEB PoToken).
        if let videoID {
            let viaTube = try await fetchSubtitlesViaInnerTube(videoID: videoID, preferLang: track.languageCode)
            if !viaTube.isEmpty { return viaTube }
        }

        // 2) Player-side capture (pot-bearing timedtext while native CC is on).
        if let webView {
            if let body = try await captureViaPlayer(webView: webView, preferLang: track.languageCode.isEmpty ? "en" : track.languageCode) {
                let parsed = parseCaptionBody(body)
                if !parsed.isEmpty { return parsed }
            }
        }

        // 3) Last resort: naked page track URL (often empty when exp=xpe / pot gated).
        if !track.baseUrl.isEmpty {
            let direct = try await downloadTrack(track, using: nil) // URLSession only — avoid page pot gates
            if !direct.isEmpty { return direct }
            if let webView {
                let viaPage = try await downloadTrack(track, using: webView)
                if !viaPage.isEmpty { return viaPage }
            }
        }
        return []
    }

    /// Fetch caption cues using ANDROID → IOS → ANDROID_VR InnerTube clients + URLSession.
    static func fetchSubtitlesViaInnerTube(videoID: String, preferLang: String) async throws -> [Subtitle] {
        let trackLists: [[CaptionTrack]] = [
            (try? await fetchTracksViaAndroid(videoID: videoID)) ?? [],
            (try? await fetchTracksViaIOS(videoID: videoID)) ?? [],
            (try? await fetchTracksViaAndroidVR(videoID: videoID)) ?? [],
        ]
        for tracks in trackLists where !tracks.isEmpty {
            let preferred = pickTrack(from: tracks, preferring: preferLang.isEmpty ? "en" : preferLang)
            let ordered = ([preferred].compactMap { $0 } + tracks).reduce(into: [CaptionTrack]()) { acc, t in
                if !acc.contains(where: { $0.baseUrl == t.baseUrl }) { acc.append(t) }
            }
            for t in ordered {
                // Always URLSession for InnerTube signed URLs — page fetch can pot-gate them.
                let subs = try await downloadTrack(t, using: nil)
                if !subs.isEmpty { return subs }
            }
        }
        return []
    }

    @MainActor
    private static func captureViaPlayer(webView: WKWebView, preferLang: String) async throws -> String? {
        // Force a fresh timedtext request: clear, toggle CC off→on.
        _ = try? await webView.evaluateJavaScript("""
            (function() {
              try { window.__tbClearCaptionCapture && window.__tbClearCaptionCapture(); } catch (e) {}
              try {
                var p = document.getElementById('movie_player')
                  || document.getElementById('shorts-player')
                  || document.querySelector('.html5-video-player');
                if (p && p.setOption) p.setOption('captions', 'track', {});
              } catch (e) {}
            })();
            """)
        try? await Task.sleep(nanoseconds: 250_000_000)
        _ = try? await webView.evaluateJavaScript(
            "window.__tbEnsureCaptionsOn && window.__tbEnsureCaptionsOn(\(jsonString(preferLang.isEmpty ? "en" : preferLang)))"
        )
        let rawValue = try await webView.callAsyncJavaScript(
            requestCaptionsAsyncJS,
            arguments: ["preferLang": preferLang.isEmpty ? "en" : preferLang],
            in: nil,
            in: .page
        )
        guard let raw = rawValue as? String,
              let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(CaptureResult.self, from: data),
              result.ok, !result.body.isEmpty else {
            return nil
        }
        return result.body
    }

    private static func jsonString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: s)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"en\""
    }

    private static func pickTrack(from tracks: [CaptionTrack], preferring languageCode: String) -> CaptionTrack? {
        if let exact = tracks.first(where: { $0.languageCode == languageCode && $0.kind != "asr" }) {
            return exact
        }
        let prefix = String(languageCode.prefix(2))
        if let lang = tracks.first(where: { $0.languageCode.hasPrefix(prefix) && $0.kind != "asr" }) {
            return lang
        }
        if let en = tracks.first(where: { $0.languageCode.hasPrefix("en") && $0.kind != "asr" }) {
            return en
        }
        if let enAsr = tracks.first(where: { $0.languageCode.hasPrefix("en") }) {
            return enAsr
        }
        return tracks.first(where: { $0.kind != "asr" }) ?? tracks.first
    }

    private static func downloadTrack(_ track: CaptionTrack, using webView: WKWebView?) async throws -> [Subtitle] {
        let base = track.baseUrl
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")
        guard !base.isEmpty else { return [] }

        let candidates = captionURLCandidates(from: base)
        var lastError: Error?

        for urlString in candidates {
            do {
                let body: String
                if let webView,
                   let viaPage = try await fetchBodyViaWebView(urlString, webView: webView),
                   viaPage.count > 20,
                   !isEmptyTimedtextBody(viaPage) {
                    body = viaPage
                } else {
                    body = try await fetchBodyViaURLSession(urlString)
                }
                if isEmptyTimedtextBody(body) { continue }
                let parsed = parseCaptionBody(body)
                if !parsed.isEmpty { return parsed }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return []
    }

    private static func isEmptyTimedtextBody(_ body: String) -> Bool {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "{}" || t == "[]" || t == "null"
    }

    static func fetchTracksViaAndroid(videoID: String) async throws -> [CaptionTrack] {
        try await fetchTracksViaInnerTube(
            videoID: videoID,
            clientName: "ANDROID",
            clientVersion: "20.10.38",
            userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip",
            clientNameHeader: "3",
            extraClient: [
                "androidSdkVersion": 34,
                "osName": "Android",
                "osVersion": "14",
            ]
        )
    }

    static func fetchTracksViaIOS(videoID: String) async throws -> [CaptionTrack] {
        try await fetchTracksViaInnerTube(
            videoID: videoID,
            clientName: "IOS",
            clientVersion: "20.10.4",
            userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 17_5 like Mac OS X)",
            clientNameHeader: "5",
            extraClient: [
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "17.5.0",
            ]
        )
    }

    static func fetchTracksViaAndroidVR(videoID: String) async throws -> [CaptionTrack] {
        try await fetchTracksViaInnerTube(
            videoID: videoID,
            clientName: "ANDROID_VR",
            clientVersion: "1.60.19",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12) gzip",
            clientNameHeader: "28",
            extraClient: [
                "androidSdkVersion": 34,
                "osName": "Android",
                "osVersion": "12",
            ]
        )
    }

    /// WEB_EMBEDDED player often still exposes captionTracks without WEB PoToken gates.
    static func fetchTracksViaEmbedded(videoID: String) async throws -> [CaptionTrack] {
        try await fetchTracksViaInnerTube(
            videoID: videoID,
            clientName: "WEB_EMBEDDED_PLAYER",
            clientVersion: "1.20240723.01.00",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
            clientNameHeader: "56",
            extraClient: [:]
        )
    }

    private static func fetchTracksViaInnerTube(
        videoID: String,
        clientName: String,
        clientVersion: String,
        userAgent: String,
        clientNameHeader: String,
        extraClient: [String: Any]
    ) async throws -> [CaptionTrack] {
        let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(clientNameHeader, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")

        var client: [String: Any] = [
            "clientName": clientName,
            "clientVersion": clientVersion,
            "hl": "en",
            "gl": "US",
        ]
        for (k, v) in extraClient { client[k] = v }

        let body: [String: Any] = [
            "context": ["client": client],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let captions = root["captions"] as? [String: Any],
              let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
              let trackObjs = renderer["captionTracks"] as? [[String: Any]] else {
            return []
        }
        let trackData = try JSONSerialization.data(withJSONObject: trackObjs)
        return (try? JSONDecoder().decode([CaptionTrack].self, from: trackData)) ?? []
    }

    private static func captionURLCandidates(from base: String) -> [String] {
        var urls: [String] = []
        func withFmt(_ fmt: String) -> String {
            var s = base
            if let range = s.range(of: #"[?&]fmt=[^&]*"#, options: .regularExpression) {
                s.replaceSubrange(range, with: String(s[range].prefix(1)) + "fmt=\(fmt)")
            } else {
                s += (s.contains("?") ? "&" : "?") + "fmt=\(fmt)"
            }
            return s
        }
        urls.append(withFmt("json3"))
        urls.append(withFmt("3"))
        urls.append(withFmt("srv3"))
        urls.append(base)
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    static let fetchBodyAsyncJS = """
    try {
      const res = await fetch(url, { credentials: 'include', cache: 'no-store' });
      if (!res.ok) return JSON.stringify({ ok: false, status: res.status, body: '' });
      const body = await res.text();
      return JSON.stringify({ ok: true, status: res.status, body: body });
    } catch (e) {
      return JSON.stringify({ ok: false, status: -1, body: String(e) });
    }
    """

    struct FetchResult: Decodable {
        let ok: Bool
        let status: Int
        let body: String
    }

    @MainActor
    private static func fetchBodyViaWebView(_ urlString: String, webView: WKWebView) async throws -> String? {
        let rawValue = try await webView.callAsyncJavaScript(
            fetchBodyAsyncJS,
            arguments: ["url": urlString],
            in: nil,
            in: .page
        )
        guard let raw = rawValue as? String,
              let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(FetchResult.self, from: data),
              result.ok, !result.body.isEmpty else {
            return nil
        }
        return result.body
    }

    private static func fetchBodyViaURLSession(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(
            "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func parseCaptionBody(_ body: String) -> [Subtitle] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let jsonSubs = JSON3Parser.parse(trimmed)
            if !jsonSubs.isEmpty { return jsonSubs }
        }
        if let data = trimmed.data(using: .utf8) {
            let xmlSubs = TimedTextParser().parse(data)
            if !xmlSubs.isEmpty { return xmlSubs }
        }
        return []
    }

    static func cleanCaptionText(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
            ("\u{00a0}", " "),
        ]
        for (from, to) in entities {
            s = s.replacingOccurrences(of: from, with: to)
        }
        while let range = s.range(of: #"&#(\d+);"#, options: .regularExpression) {
            let token = String(s[range])
            if let num = Int(token.dropFirst(2).dropLast()), let scalar = UnicodeScalar(num) {
                s.replaceSubrange(range, with: String(Character(scalar)))
            } else {
                break
            }
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - JSON3 (YouTube fmt=json3)

enum JSON3Parser {
    static func parse(_ text: String) -> [Subtitle] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else {
            return []
        }
        var raw: [(start: Double, duration: Double, text: String)] = []
        for event in events {
            guard let segs = event["segs"] as? [[String: Any]] else { continue }
            let startMs = (event["tStartMs"] as? Double) ?? Double(event["tStartMs"] as? Int ?? 0)
            let durMs = (event["dDurationMs"] as? Double) ?? Double(event["dDurationMs"] as? Int ?? -1)
            let joined = segs.compactMap { $0["utf8"] as? String }.joined()
            let cleaned = SubtitleExtractor.cleanCaptionText(joined)
            guard !cleaned.isEmpty else { continue }
            raw.append((startMs / 1000.0, durMs >= 0 ? durMs / 1000.0 : -1, cleaned))
        }
        var subs: [Subtitle] = []
        for i in raw.indices {
            var duration = raw[i].duration
            if duration < 0 {
                if i + 1 < raw.count {
                    duration = max(raw[i + 1].start - raw[i].start, 0.001)
                } else {
                    duration = 2.0
                }
            }
            // Clip to next cue start — never invent overlap (that breaks A/V sync).
            if i + 1 < raw.count {
                let gap = raw[i + 1].start - raw[i].start
                if gap > 0 {
                    duration = min(duration, gap)
                }
            }
            subs.append(Subtitle(start: raw[i].start, duration: max(duration, 0.001), text: raw[i].text))
        }
        // Keep original cue boundaries — merging identical lines across gaps breaks A/V sync.
        return subs
    }
}

// MARK: - XML timedtext (fmt=3 / srv3)

final class TimedTextParser: NSObject, XMLParserDelegate {
    private var subtitles: [Subtitle] = []
    private var currentText = ""
    private var currentStart: Double = 0
    private var currentDur: Double = 0
    private var inText = false

    func parse(_ data: Data) -> [Subtitle] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        // Clip each cue to the next start so XML tracks match json3 timing rules.
        guard subtitles.count > 1 else { return subtitles }
        var clipped: [Subtitle] = []
        clipped.reserveCapacity(subtitles.count)
        for i in subtitles.indices {
            let sub = subtitles[i]
            var duration = max(sub.duration, 0.001)
            if i + 1 < subtitles.count {
                let gap = subtitles[i + 1].start - sub.start
                if gap > 0 { duration = min(duration, gap) }
            }
            clipped.append(Subtitle(start: sub.start, duration: duration, text: sub.text, translation: sub.translation))
        }
        return clipped
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "text" || elementName == "p" {
            inText = true
            currentText = ""
            if let start = attributeDict["start"] {
                currentStart = Double(start) ?? Self.parseClock(start)
            } else if let begin = attributeDict["begin"] {
                currentStart = Self.parseClock(begin)
            } else {
                currentStart = 0
            }
            if let dur = attributeDict["dur"] {
                currentDur = Double(dur) ?? Self.parseClock(dur)
            } else if let end = attributeDict["end"] {
                currentDur = max(Self.parseClock(end) - currentStart, 0)
            } else {
                currentDur = 0
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "text" || elementName == "p" {
            inText = false
            let cleaned = SubtitleExtractor.cleanCaptionText(currentText)
            if !cleaned.isEmpty {
                subtitles.append(Subtitle(start: currentStart, duration: max(currentDur, 0.05), text: cleaned))
            }
        }
    }

    private static func parseClock(_ value: String) -> Double {
        if let plain = Double(value) { return plain }
        let parts = value.split(separator: ":").map(String.init)
        guard !parts.isEmpty else { return 0 }
        var seconds = 0.0
        if parts.count == 3 {
            seconds += (Double(parts[0]) ?? 0) * 3600
            seconds += (Double(parts[1]) ?? 0) * 60
            seconds += Double(parts[2]) ?? 0
        } else if parts.count == 2 {
            seconds += (Double(parts[0]) ?? 0) * 60
            seconds += Double(parts[1]) ?? 0
        }
        return seconds
    }
}
