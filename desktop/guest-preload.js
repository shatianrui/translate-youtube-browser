/**
 * Runs inside each <webview> guest page BEFORE any page scripts.
 * Sets up IPC bridge and injects the fetch/XHR timedtext hooks early enough
 * to capture YouTube's own PoToken-bearing caption downloads.
 */
const { ipcRenderer } = require('electron');

window.__tbPost = function tbPost(name, payload) {
  try {
    ipcRenderer.sendToHost(name, payload);
  } catch (_) {
    // Guest may be navigating away.
  }
};

window.webkit = window.webkit || {};
window.webkit.messageHandlers = window.webkit.messageHandlers || {};
['tbUrlChanged', 'tbActiveIndex', 'tbCaptionBody'].forEach((name) => {
  window.webkit.messageHandlers[name] = {
    postMessage(payload) {
      window.__tbPost(name, payload);
    },
  };
});

// Early fetch/XHR hooks — must run before YouTube's player scripts load.
// The full overlay (caption rendering, rAF loop, etc.) is injected later via dom-ready.
(function earlyTimedtextCapture() {
  if (!/youtube\.com|youtu\.be/i.test(location.hostname || '')) return;
  window.__tbCapturedBody = null;
  window.__tbCapturedURL = null;
  window.__tbCaptionWaiters = [];

  function isAdPlaying() {
    try {
      var player = document.getElementById('movie_player') || document.querySelector('.html5-video-player');
      if (!player) return false;
      var cls = player.className || '';
      return cls.indexOf('ad-showing') >= 0 || cls.indexOf('ad-interrupting') >= 0;
    } catch (_) { return false; }
  }

  function captureTimedtext(url, body) {
    try {
      if (!url || String(url).indexOf('/api/timedtext') === -1) return;
      if (isAdPlaying()) return;
      window.__tbCapturedURL = String(url);
      if (!body || !String(body).trim() || String(body).trim().length < 20) return;
      var trimmed = String(body).trim();
      if (trimmed === '{}' || trimmed === '[]') return;
      window.__tbCapturedBody = String(body);
      window.__tbPost('tbCaptionBody', { url: String(url), body: String(body) });
      var waiters = (window.__tbCaptionWaiters || []).splice(0);
      waiters.forEach(function(cb) { try { cb(String(body), String(url)); } catch (_) {} });
    } catch (_) {}
  }

  // Hook fetch
  try {
    var nativeFetch = window.fetch;
    window.fetch = function() {
      var args = arguments;
      var input = args[0];
      var url = (typeof input === 'string') ? input : (input && input.url);
      return nativeFetch.apply(this, args).then(function(res) {
        try {
          if (url && String(url).indexOf('/api/timedtext') !== -1) {
            res.clone().text().then(function(t) { captureTimedtext(url, t); }).catch(function() {});
          }
        } catch (_) {}
        return res;
      });
    };
  } catch (_) {}

  // Hook XHR
  try {
    var xOpen = XMLHttpRequest.prototype.open;
    var xSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, url) {
      this.__tbURL = url;
      return xOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function() {
      var xhr = this;
      if (xhr.__tbURL && String(xhr.__tbURL).indexOf('/api/timedtext') !== -1) {
        xhr.addEventListener('load', function() {
          try { captureTimedtext(xhr.__tbURL, xhr.responseText); } catch (_) {}
        });
      }
      return xSend.apply(this, arguments);
    };
  } catch (_) {}

  window.__tbFetchPatched = true;
})();
