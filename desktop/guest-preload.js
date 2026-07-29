/**
 * Runs inside each <webview> guest page so the injected overlay can talk back
 * to the host UI via ipcRenderer.sendToHost.
 */
const { ipcRenderer } = require('electron');

window.__tbPost = function tbPost(name, payload) {
  try {
    ipcRenderer.sendToHost(name, payload);
  } catch (_) {
    // Guest may be navigating away.
  }
};

// Also expose a webkit-compatible shim so the shared overlay script can stay close to iOS.
window.webkit = window.webkit || {};
window.webkit.messageHandlers = window.webkit.messageHandlers || {};
['tbUrlChanged', 'tbActiveIndex'].forEach((name) => {
  window.webkit.messageHandlers[name] = {
    postMessage(payload) {
      window.__tbPost(name, payload);
    },
  };
});
