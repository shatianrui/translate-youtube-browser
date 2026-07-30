const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('tbDesktop', {
  getSettings: () => ipcRenderer.invoke('settings:get'),
  setSettings: (patch) => ipcRenderer.invoke('settings:set', patch),
  listBookmarks: () => ipcRenderer.invoke('bookmarks:list'),
  setBookmarks: (bookmarks) => ipcRenderer.invoke('bookmarks:set', bookmarks),
  openExternal: (url) => ipcRenderer.invoke('shell:openExternal', url),
  getGuestPreloadPath: () => ipcRenderer.invoke('app:getGuestPreloadPath'),
  getVersion: () => ipcRenderer.invoke('app:getVersion'),
  fetchText: (url, headers) => ipcRenderer.invoke('net:fetchText', url, headers),
  fetchInnerTubeTracks: (videoID) => ipcRenderer.invoke('net:fetchInnerTubeTracks', videoID),
  translate: (request) => ipcRenderer.invoke('net:translate', request),
  onMenuNewTab: (cb) => {
    const handler = () => cb();
    ipcRenderer.on('menu-new-tab', handler);
    return () => ipcRenderer.removeListener('menu-new-tab', handler);
  },
  onMenuNewPrivateTab: (cb) => {
    const handler = () => cb();
    ipcRenderer.on('menu-new-private-tab', handler);
    return () => ipcRenderer.removeListener('menu-new-private-tab', handler);
  },
  onMenuCloseTab: (cb) => {
    const handler = () => cb();
    ipcRenderer.on('menu-close-tab', handler);
    return () => ipcRenderer.removeListener('menu-close-tab', handler);
  },
  onMenuOpenYouTube: (cb) => {
    const handler = () => cb();
    ipcRenderer.on('menu-open-youtube', handler);
    return () => ipcRenderer.removeListener('menu-open-youtube', handler);
  },
  onOpenExternalUrl: (cb) => {
    const handler = (_e, url) => cb(url);
    ipcRenderer.on('open-external-url', handler);
    return () => ipcRenderer.removeListener('open-external-url', handler);
  },
});
