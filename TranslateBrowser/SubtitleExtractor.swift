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
    """

    /// Injected at document-start. Hooks fetch/XHR to capture the player's own timedtext
    /// responses (which already carry a valid PoToken), renders bilingual overlay inside the
    /// player DOM, and reports SPA navigations back to Swift.
    static let bilingualOverlayJS = """
    (function() {
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
          }, 9000);
          window.__tbCaptionWaiters.push(function(b) {
            if (!settled) { settled = true; clearTimeout(timer); resolve(b); }
          });
          // Nudge again a couple times — player module can lag after SPA nav
          setTimeout(function() { enableNativeCaptions(preferLang || 'en'); }, 1200);
          setTimeout(function() { enableNativeCaptions(preferLang || 'en'); }, 2800);
        });

        if (!body) return JSON.stringify({ ok: false, body: '', url: window.__tbCapturedURL || '' });

        // Prefer json3 for reliable parsing
        var url = window.__tbCapturedURL || '';
        if (url) {
          try {
            var u = new URL(url, location.origin);
            u.searchParams.set('fmt', 'json3');
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
        return (container && container.querySelector('video')) || document.querySelector('video');
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

      // --- Bilingual overlay: embedded inside the video host, not a browser chrome popup ---
      var style = document.createElement('style');
      style.textContent = [
        '.ytp-caption-window-container,.caption-window{display:none !important;}',
        'video{z-index:1;}',
        '#tb-bilingual-caption{position:absolute;left:50%;bottom:8%;transform:translateX(-50%);',
        'width:max-content;max-width:90%;z-index:2147483647;pointer-events:none;text-align:center;',
        'font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;',
        'display:none;}',
        '#tb-caption-orig{color:rgba(255,255,255,0.88);font-size:clamp(11px,1.8vw,14px);',
        'line-height:1.35;text-shadow:0 1px 3px rgba(0,0,0,0.95),0 0 8px rgba(0,0,0,0.6);',
        'margin-bottom:4px;white-space:pre-wrap;}',
        '#tb-caption-trans{color:#fff;font-size:clamp(15px,2.6vw,22px);font-weight:600;line-height:1.35;',
        'text-shadow:0 1px 4px rgba(0,0,0,0.95);background:rgba(0,0,0,0.55);border-radius:8px;',
        'padding:5px 12px;display:none;white-space:pre-wrap;}'
      ].join('');
      (document.documentElement || document.head || document.body).appendChild(style);

      function ensureOverlay() {
        var host = findVideoHost();
        if (!host) return null;
        var el = document.getElementById('tb-bilingual-caption');
        if (el && el.parentElement === host) return el;
        if (el) el.remove();
        el = document.createElement('div');
        el.id = 'tb-bilingual-caption';
        var orig = document.createElement('div');
        orig.id = 'tb-caption-orig';
        var trans = document.createElement('div');
        trans.id = 'tb-caption-trans';
        el.appendChild(orig);
        el.appendChild(trans);
        var pos = getComputedStyle(host).position;
        if (pos === 'static' || !pos) host.style.position = 'relative';
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
        forceAllVideosInline(document);
        var host = findVideoHost();
        var video = findVideo(host);
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
      document.addEventListener('fullscreenchange', function() { lastIndex = -2; tick(); });
      document.addEventListener('webkitfullscreenchange', function() { lastIndex = -2; tick(); });
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

    /// Primary path: let the YouTube player itself fetch timedtext (valid pot), intercept it.
    /// Fallbacks: ANDROID_VR InnerTube tracks, then direct URLSession of page track URLs.
    static func fetchSubtitles(
        from track: CaptionTrack,
        videoID: String?,
        using webView: WKWebView?
    ) async throws -> [Subtitle] {
        // 1) Player-side capture (works even when WEB timedtext requires PoToken)
        if let webView {
            if let body = try await captureViaPlayer(webView: webView, preferLang: track.languageCode) {
                let parsed = parseCaptionBody(body)
                if !parsed.isEmpty { return parsed }
            }
        }

        // 2) ANDROID_VR track URLs (no PoToken on subs currently)
        if let videoID {
            let vrTracks = try await fetchTracksViaAndroidVR(videoID: videoID)
            let preferred = pickTrack(from: vrTracks, preferring: track.languageCode) ?? vrTracks.first
            if let preferred {
                let vrSubs = try await downloadTrack(preferred, using: webView)
                if !vrSubs.isEmpty { return vrSubs }
            }
            for t in vrTracks {
                let subs = try await downloadTrack(t, using: nil)
                if !subs.isEmpty { return subs }
            }
        }

        // 3) Last resort: direct download of the page track (often empty when exp=xpe)
        return try await downloadTrack(track, using: webView)
    }

    @MainActor
    private static func captureViaPlayer(webView: WKWebView, preferLang: String) async throws -> String? {
        _ = try? await webView.evaluateJavaScript("window.__tbClearCaptionCapture && window.__tbClearCaptionCapture()")
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
        return tracks.first(where: { $0.kind != "asr" }) ?? tracks.first
    }

    private static func downloadTrack(_ track: CaptionTrack, using webView: WKWebView?) async throws -> [Subtitle] {
        let base = track.baseUrl
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")

        let candidates = captionURLCandidates(from: base)
        var lastError: Error?

        for urlString in candidates {
            do {
                let body: String
                if let webView,
                   let viaPage = try await fetchBodyViaWebView(urlString, webView: webView),
                   !viaPage.isEmpty {
                    body = viaPage
                } else {
                    body = try await fetchBodyViaURLSession(urlString)
                }
                let parsed = parseCaptionBody(body)
                if !parsed.isEmpty { return parsed }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return []
    }

    static func fetchTracksViaAndroidVR(videoID: String) async throws -> [CaptionTrack] {
        let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12) gzip",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("28", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue("1.60.19", forHTTPHeaderField: "X-Youtube-Client-Version")

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID_VR",
                    "clientVersion": "1.60.19",
                    "hl": "en",
                    "gl": "US",
                    "androidSdkVersion": 34,
                    "osName": "Android",
                    "osVersion": "12",
                ]
            ],
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
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
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
                    duration = max(raw[i + 1].start - raw[i].start, 0.05)
                } else {
                    duration = 2.0
                }
            }
            subs.append(Subtitle(start: raw[i].start, duration: max(duration, 0.05), text: raw[i].text))
        }
        return mergeAdjacentDuplicates(subs)
    }

    private static func mergeAdjacentDuplicates(_ subs: [Subtitle]) -> [Subtitle] {
        guard !subs.isEmpty else { return [] }
        var out: [Subtitle] = []
        for sub in subs {
            if let last = out.last, last.text == sub.text, sub.start <= last.start + last.duration + 0.2 {
                let end = max(last.start + last.duration, sub.start + sub.duration)
                out[out.count - 1] = Subtitle(start: last.start, duration: end - last.start, text: last.text)
            } else {
                out.append(sub)
            }
        }
        return out
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
        return subtitles
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
