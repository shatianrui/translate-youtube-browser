import Foundation

/// 注入到网页中的脚本:拦截 YouTube 的 /api/timedtext 字幕请求,
/// 把字幕文本发给原生端翻译,并在播放器上渲染双语叠加层。
enum SubtitleScript {
    static let messageHandlerName = "tbBridge"

    static let source = #"""
    (function () {
      if (window.__tbInstalled) { return; }
      window.__tbInstalled = true;

      var CUES = [];            // { start, end, text }
      var TRANSLATIONS = {};    // index -> 译文
      var overlayEl = null;
      var lastShownIndex = -2;

      function post(name, payload) {
        try {
          window.webkit.messageHandlers.tbBridge.postMessage({ name: name, payload: payload });
        } catch (e) {}
      }

      function forceJson3(url) {
        try {
          var u = new URL(url, location.href);
          u.searchParams.set('fmt', 'json3');
          return u.toString();
        } catch (e) { return url; }
      }

      function handleTimedText(text) {
        try {
          var data = JSON.parse(text);
          if (!data || !data.events) { return; }
          var cues = [];
          for (var i = 0; i < data.events.length; i++) {
            var ev = data.events[i];
            if (!ev.segs) { continue; }
            var t = ev.segs.map(function (s) { return s.utf8 || ''; }).join('')
              .replace(/\n/g, ' ').replace(/\s+/g, ' ').trim();
            if (!t) { continue; }
            var start = (ev.tStartMs || 0) / 1000;
            var dur = (ev.dDurationMs || 3000) / 1000;
            cues.push({ start: start, end: start + dur, text: t });
          }
          if (!cues.length) { return; }
          CUES = cues;
          TRANSLATIONS = {};
          lastShownIndex = -2;
          ensureOverlay();
          post('cues', cues.map(function (c) { return c.text; }));
        } catch (e) {}
      }

      // 原生端翻译完成后回调:startIndex 起的一批译文。
      window.__tbApplyTranslations = function (startIndex, arr) {
        for (var i = 0; i < arr.length; i++) {
          TRANSLATIONS[startIndex + i] = arr[i];
        }
        lastShownIndex = -2; // 强制刷新当前显示
      };

      // ---- 拦截 fetch ----
      var origFetch = window.fetch;
      window.fetch = function (input, init) {
        var url = (typeof input === 'string') ? input
          : (input && input.url) ? input.url : '';
        if (url && url.indexOf('/api/timedtext') !== -1) {
          return origFetch(forceJson3(url), init).then(function (res) {
            try {
              res.clone().text().then(handleTimedText).catch(function () {});
            } catch (e) {}
            return res;
          });
        }
        return origFetch.apply(this, arguments);
      };

      // ---- 拦截 XHR ----
      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__tbTimedText = url && String(url).indexOf('/api/timedtext') !== -1;
        if (this.__tbTimedText) {
          arguments[1] = forceJson3(String(url));
          this.addEventListener('load', function () {
            try { handleTimedText(this.responseText); } catch (e) {}
          });
        }
        return origOpen.apply(this, arguments);
      };

      // ---- 双语叠加层 ----
      function ensureOverlay() {
        if (overlayEl && document.body.contains(overlayEl)) { return; }
        var player = document.querySelector('#movie_player') ||
                     document.querySelector('.html5-video-player');
        if (!player) { return; }
        overlayEl = document.createElement('div');
        overlayEl.id = '__tb_overlay';
        overlayEl.style.cssText = [
          'position:absolute', 'left:50%', 'transform:translateX(-50%)',
          'bottom:8%', 'max-width:92%', 'z-index:9999',
          'pointer-events:none', 'text-align:center', 'display:none'
        ].join(';');
        player.appendChild(overlayEl);

        if (!document.getElementById('__tb_style')) {
          var style = document.createElement('style');
          style.id = '__tb_style';
          style.textContent =
            '.ytp-caption-window-container{display:none !important;}' +
            '#__tb_overlay .tb-line{display:inline-block;padding:2px 10px;margin:2px 0;' +
            'border-radius:6px;background:rgba(0,0,0,0.72);color:#fff;' +
            'font-size:clamp(13px, 2.6vw, 24px);line-height:1.45;}' +
            '#__tb_overlay .tb-trans{color:#ffd75e;font-weight:600;}';
          document.head.appendChild(style);
        }
      }

      function currentCueIndex(time) {
        for (var i = 0; i < CUES.length; i++) {
          if (time >= CUES[i].start && time <= CUES[i].end) { return i; }
        }
        return -1;
      }

      function escapeHtml(s) {
        return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
      }

      function tick() {
        if (!CUES.length) { return; }
        ensureOverlay();
        if (!overlayEl) { return; }
        var video = document.querySelector('video');
        if (!video) { return; }
        var idx = currentCueIndex(video.currentTime);
        if (idx === lastShownIndex) { return; }
        lastShownIndex = idx;
        if (idx === -1) {
          overlayEl.style.display = 'none';
          return;
        }
        var original = escapeHtml(CUES[idx].text);
        var translated = TRANSLATIONS[idx];
        var html = '<span class="tb-line">' + original + '</span>';
        if (translated) {
          html += '<br><span class="tb-line tb-trans">' + escapeHtml(translated) + '</span>';
        }
        overlayEl.innerHTML = html;
        overlayEl.style.display = 'block';
      }

      setInterval(tick, 250);
    })();
    """#
}
