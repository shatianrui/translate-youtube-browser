import Foundation
import WebKit

/// YouTube ad blocking: WK content rules (network) + page script (skip/hide leftovers).
enum YouTubeAdBlock {
    /// Domains/paths used for ads — never block googlevideo / timedtext / player CDN needed for playback.
    static let contentRuleJSON = """
    [
      {"trigger":{"url-filter":".*doubleclick\\\\.net.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*googleadservices\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*googlesyndication\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*pagead2\\\\..*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*pagead\\\\..*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*adservice\\\\.google\\\\..*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*youtube\\\\.com\\\\/pagead\\\\/.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*youtube\\\\.com\\\\/ptracking.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*youtube\\\\.com\\\\/api\\\\/stats\\\\/ads.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*youtube\\\\.com\\\\/get_midroll_.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*youtube\\\\.com\\\\/youtubei\\\\/v1\\\\/player\\\\/ad_.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*googleads\\\\.g\\\\.doubleclick\\\\.net.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*ad\\\\.youtube\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*static\\\\.doubleclick\\\\.net.*"},"action":{"type":"block"}}
    ]
    """

    static func installContentRules(into controller: WKUserContentController) async {
        let id = "TranslateBrowserYouTubeAds"
        do {
            let store = WKContentRuleListStore.default()
            if let existing = try await store.contentRuleList(forIdentifier: id) {
                controller.add(existing)
                return
            }
            guard let compiled = try await store.compileContentRuleList(
                forIdentifier: id,
                encodedContentRuleList: contentRuleJSON
            ) else { return }
            controller.add(compiled)
        } catch {
            // Ad rules are best-effort; playback must still work without them.
        }
    }

    /// Skip in-player ads and hide ad slots without touching the main video stream.
    static let skipAdsJS = """
    (function() {
      if (window.__tbAdBlockInstalled) return;
      window.__tbAdBlockInstalled = true;

      var style = document.createElement('style');
      style.textContent = [
        'ytd-ad-slot-renderer,ytd-promoted-sparkles-text-search-renderer,',
        'ytd-promoted-sparkles-web-renderer,ytd-player-legacy-desktop-watch-ads-renderer,',
        'ytd-action-companion-ad-renderer,ytd-display-ad-renderer,',
        'ytd-in-feed-ad-layout-renderer,ytd-ad-slot-renderer,',
        '#player-ads,.ytp-ad-module,.ytp-ad-overlay-container,.ytp-ad-progress-list,',
        '.video-ads,.ytp-ad-image-overlay,.ytp-ad-text-overlay,',
        'ytd-rich-item-renderer:has(ytd-ad-slot-renderer),',
        'ytd-reel-video-renderer:has(ytd-ad-slot-renderer){display:none !important;}'
      ].join('');
      (document.documentElement || document.head).appendChild(style);

      function player() {
        return document.getElementById('movie_player')
          || document.getElementById('shorts-player')
          || document.querySelector('.html5-video-player');
      }

      function clickSkip() {
        var btn = document.querySelector(
          '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button,' +
          'button.ytp-ad-skip-button-container, .ytp-ad-skip-button-container button,' +
          '.ytp-ad-overlay-close-button'
        );
        if (btn) { try { btn.click(); return true; } catch (e) {} }
        return false;
      }

      function skipAd() {
        clickSkip();
        var p = player();
        var video = document.querySelector('video');
        try {
          if (p && p.getPlayerResponse) {
            // Some builds expose ad state via class names.
          }
        } catch (e) {}
        var adShowing = !!(document.querySelector('.ad-showing, .ytp-ad-player-overlay, .ytp-ad-text'));
        if (adShowing && video) {
          try {
            if (video.duration && isFinite(video.duration) && video.duration > 0) {
              video.currentTime = Math.max(0, video.duration - 0.2);
            }
            video.playbackRate = 16;
          } catch (e) {}
          clickSkip();
        } else if (video && video.playbackRate > 4) {
          try { video.playbackRate = 1; } catch (e) {}
        }
      }

      setInterval(skipAdsSafe, 600);
      function skipAdsSafe() { try { skipAd(); } catch (e) {} }
      document.addEventListener('yt-navigate-finish', function() {
        setTimeout(skipAdsSafe, 300);
        setTimeout(skipAdsSafe, 1200);
      }, true);
    })();
    """
}
