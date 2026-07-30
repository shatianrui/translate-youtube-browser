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
      if ((!pr || !pr.captions) && window.ytInitialData) {
        try {
          var contents = (ytInitialData.contents && ytInitialData.contents.twoColumnWatchNextResults) || null;
        } catch (e) {}
      }
      var tracks = pr && pr.captions && pr.captions.playerCaptionsTracklistRenderer && pr.captions.playerCaptionsTracklistRenderer.captionTracks;
      return tracks ? JSON.stringify(tracks) : "[]";
    })()
    """

    /// Body of `callAsyncJavaScript` — must `return` (not rely on evaluateJavaScript, which
    /// does not await Promises). `url` is passed via the arguments dictionary.
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

    /// Injected once per page load. Renders bilingual captions inside the YouTube player DOM
    /// (so they survive DOM fullscreen), reports native/DOM fullscreen state to Swift for
    /// landscape rotation, and reports SPA navigations back to Swift.
    static let bilingualOverlayJS = """
    (function() {
      if (window.__tbInstalled) return;
      window.__tbInstalled = true;
      window.__tbSubs = [];

      function post(name, payload) {
        try { window.webkit.messageHandlers[name].postMessage(payload); } catch (e) {}
      }

      function notifyURL() { post('tbUrlChanged', location.href); }
      ['yt-navigate-finish', 'yt-page-data-updated', 'yt-navigate-start'].forEach(function(evt) {
        window.addEventListener(evt, notifyURL, true);
        document.addEventListener(evt, notifyURL, true);
      });
      window.addEventListener('popstate', notifyURL);

      // Do not replace webkitEnterFullscreen: doing so stops WKWebView from presenting the
      // native iOS video player. Listen to both native-video and DOM fullscreen events instead
      // and let Swift lock the app to landscape while playback is fullscreen.
      function notifyFullscreen(isFullscreen) { post('tbFullscreenChanged', !!isFullscreen); }
      document.addEventListener('fullscreenchange', function() { notifyFullscreen(document.fullscreenElement); }, true);
      document.addEventListener('webkitfullscreenchange', function() {
        notifyFullscreen(document.webkitFullscreenElement);
      }, true);
      document.addEventListener('webkitbeginfullscreen', function(e) {
        if (e.target && e.target.tagName === 'VIDEO') notifyFullscreen(true);
      }, true);
      document.addEventListener('webkitendfullscreen', function(e) {
        if (e.target && e.target.tagName === 'VIDEO') notifyFullscreen(false);
      }, true);
      var _ps = history.pushState;
      history.pushState = function() { var r = _ps.apply(this, arguments); setTimeout(notifyURL, 0); return r; };
      var _rs = history.replaceState;
      history.replaceState = function() { var r = _rs.apply(this, arguments); setTimeout(notifyURL, 0); return r; };

      var style = document.createElement('style');
      style.textContent = [
        '.ytp-caption-window-container{display:none !important;}',
        '#tb-bilingual-caption{position:absolute;left:50%;bottom:9%;transform:translateX(-50%);',
        'max-width:min(92%,720px);z-index:2147483647;pointer-events:none;text-align:center;',
        'font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;}',
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
        // Binary-ish linear scan is fine for typical caption counts; prefer exact window, then
        // fall back to the nearest previous cue if gaps between cues are large.
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

    })();
    """

    struct FetchResult: Decodable {
        let ok: Bool
        let status: Int
        let body: String
    }

    /// Multi-strategy caption download.
    /// YouTube's WEB caption `baseUrl` often includes `exp=xpe`, which requires a BotGuard
    /// PoToken — without it timedtext returns HTTP 200 with an empty body. Strategies:
    ///  1. Try the page track URL via in-page `fetch` (cookies) and URLSession.
    ///  2. If empty / PoToken-gated, resolve fresh tracks via InnerTube `ANDROID_VR`
    ///     (no PoToken on subs) and download those.
    static func fetchSubtitles(
        from track: CaptionTrack,
        videoID: String?,
        using webView: WKWebView?
    ) async throws -> [Subtitle] {
        let pageSubs = try await downloadTrack(track, using: webView)
        if !pageSubs.isEmpty { return pageSubs }

        if let videoID {
            let vrTracks = try await fetchTracksViaAndroidVR(videoID: videoID)
            let preferred = pickTrack(from: vrTracks, preferring: track.languageCode) ?? vrTracks.first
            if let preferred {
                let vrSubs = try await downloadTrack(preferred, using: nil)
                if !vrSubs.isEmpty { return vrSubs }
            }
            // Last resort: try every VR track
            for t in vrTracks {
                let subs = try await downloadTrack(t, using: nil)
                if !subs.isEmpty { return subs }
            }
        }
        return []
    }

    private static func pickTrack(from tracks: [CaptionTrack], preferring languageCode: String) -> CaptionTrack? {
        if let exact = tracks.first(where: { $0.languageCode == languageCode && $0.kind != "asr" }) {
            return exact
        }
        if let lang = tracks.first(where: { $0.languageCode.hasPrefix(String(languageCode.prefix(2))) && $0.kind != "asr" }) {
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

    /// InnerTube ANDROID_VR player — currently returns caption URLs that do not require PoToken.
    static func fetchTracksViaAndroidVR(videoID: String) async throws -> [CaptionTrack] {
        let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
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

    @MainActor
    private static func fetchBodyViaWebView(_ urlString: String, webView: WKWebView) async throws -> String? {
        // WebKit's completion-handler API returns the JavaScript value. Its async overlay can
        // resolve to Void on newer SDKs, silently discarding the fetch result and forcing a
        // less reliable out-of-process URLSession request.
        let rawValue: Any = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                fetchBodyAsyncJS,
                arguments: ["url": urlString],
                in: nil,
                in: .page,
                completionHandler: { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            )
        }
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
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
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
        // Fill missing durations from the gap until the next cue (common in ASR karaoke JSON3).
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
            // XML timedtext uses seconds; TTML may use begin/dur clocks — handle both.
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
        // HH:MM:SS.mmm or MM:SS.mmm
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
