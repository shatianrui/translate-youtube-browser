import Foundation

enum SubtitleExtractor {
    // window.ytInitialPlayerResponse only reflects the video that was present in the initial
    // HTML payload; YouTube is a single-page app, so navigating to another video in-page does
    // not refresh that global. The in-page player instance's own getPlayerResponse() always
    // reflects whatever is currently loaded, so prefer it and fall back for the very first load.
    static let captionTracksJS = """
    (function() {
      function liveResponse() {
        try {
          var player = document.getElementById('movie_player');
          if (player && typeof player.getPlayerResponse === 'function') {
            var r = player.getPlayerResponse();
            if (r && r.captions) return r;
          }
        } catch (e) {}
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

    /// Injected once per page load. Does three things entirely inside the page's own JS context
    /// so they keep working even while the page is fullscreen (a Swift-side overlay drawn on top
    /// of the WKWebView is not part of the fullscreen element and gets covered by it):
    ///  1. Renders the bilingual caption as a DOM node appended *inside* the YouTube player
    ///     container, driven by the real <video>'s `timeupdate` event — so it sits inside the
    ///     video's own box and is included when that box goes fullscreen.
    ///  2. Redirects the legacy `webkitEnterFullscreen()` call to the standards
    ///     `Element.requestFullscreen()` on the player container (paired with
    ///     `WKPreferences.isElementFullscreenEnabled` on the Swift side) so "fullscreen" stays a
    ///     DOM-level style change inside our WKWebView instead of popping a separate native video
    ///     window that covers everything, including our caption node.
    ///  3. Detects YouTube's in-page (History API) navigation and reports it back to Swift, as a
    ///     second, redundant signal alongside KVO on WKWebView.url.
    static let bilingualOverlayJS = """
    (function() {
      if (window.__tbInstalled) return;
      window.__tbInstalled = true;
      window.__tbSubs = [];

      function post(name, payload) {
        try { window.webkit.messageHandlers[name].postMessage(payload); } catch (e) {}
      }

      function notifyURL() { post('tbUrlChanged', location.href); }
      ['yt-navigate-finish', 'yt-page-data-updated'].forEach(function(evt) {
        window.addEventListener(evt, notifyURL, true);
        document.addEventListener(evt, notifyURL, true);
      });
      window.addEventListener('popstate', notifyURL);
      var _ps = history.pushState;
      history.pushState = function() { var r = _ps.apply(this, arguments); notifyURL(); return r; };
      var _rs = history.replaceState;
      history.replaceState = function() { var r = _rs.apply(this, arguments); notifyURL(); return r; };

      // Avoid double captions if the user also has YouTube's native CC turned on.
      var style = document.createElement('style');
      style.textContent = '.ytp-caption-window-container{display:none !important;}';
      document.documentElement.appendChild(style);

      function findPlayerContainer() {
        return document.getElementById('movie_player') || document.querySelector('.html5-video-player');
      }
      function findVideo(container) {
        return (container && container.querySelector('video')) || document.querySelector('video');
      }
      function ensureOverlay() {
        var container = findPlayerContainer();
        if (!container) return null;
        var el = document.getElementById('tb-bilingual-caption');
        if (el && el.parentElement === container) return el;
        if (el) el.remove();
        el = document.createElement('div');
        el.id = 'tb-bilingual-caption';
        el.style.cssText = 'position:absolute;left:50%;bottom:9%;transform:translateX(-50%);max-width:82%;z-index:2147483647;pointer-events:none;text-align:center;display:none;font-family:-apple-system,BlinkMacSystemFont,sans-serif;';
        var orig = document.createElement('div');
        orig.id = 'tb-caption-orig';
        orig.style.cssText = 'color:rgba(255,255,255,0.78);font-size:13px;line-height:1.4;text-shadow:0 1px 3px rgba(0,0,0,0.9);margin-bottom:3px;';
        var trans = document.createElement('div');
        trans.id = 'tb-caption-trans';
        trans.style.cssText = 'color:#fff;font-size:19px;font-weight:600;line-height:1.4;text-shadow:0 1px 4px rgba(0,0,0,0.9);background:rgba(0,0,0,0.4);border-radius:8px;padding:4px 10px;display:none;';
        el.appendChild(orig);
        el.appendChild(trans);
        if (getComputedStyle(container).position === 'static') container.style.position = 'relative';
        container.appendChild(el);
        return el;
      }
      function findCue(t) {
        var subs = window.__tbSubs;
        for (var i = 0; i < subs.length; i++) {
          var s = subs[i];
          if (t >= s.s && t <= s.s + Math.max(s.d || 0, 0.8)) return i;
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
      setInterval(tick, 400);

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

      try {
        var proto = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
        if (proto && proto.webkitEnterFullscreen) {
          var original = proto.webkitEnterFullscreen;
          proto.webkitEnterFullscreen = function() {
            var self = this;
            var args = arguments;
            var container = findPlayerContainer();
            if (container && container.requestFullscreen) {
              container.requestFullscreen().catch(function() { original.apply(self, args); });
            } else {
              original.apply(self, args);
            }
          };
        }
      } catch (e) {}
    })();
    """

    static func fetchSubtitles(from track: CaptionTrack) async throws -> [Subtitle] {
        let urlString = track.baseUrl.replacingOccurrences(of: "\\u0026", with: "&")
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return TimedTextParser().parse(data)
    }
}

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
        if elementName == "text" {
            inText = true
            currentText = ""
            currentStart = Double(attributeDict["start"] ?? "") ?? 0
            currentDur = Double(attributeDict["dur"] ?? "") ?? 0
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "text" {
            inText = false
            let cleaned = currentText
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                subtitles.append(Subtitle(start: currentStart, duration: currentDur, text: cleaned))
            }
        }
    }
}
