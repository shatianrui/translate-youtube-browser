const { app, BrowserWindow, ipcMain, shell, Menu } = require('electron');
const path = require('path');
const Store = require('electron-store');

const store = new Store({
  name: 'translate-browser',
  defaults: {
    provider: 'ChatGPT (OpenAI)',
    apiKey: '',
    model: '',
    targetLang: '中文',
    bookmarks: [],
    windowBounds: { width: 1280, height: 840 },
  },
});

/** @type {BrowserWindow | null} */
let mainWindow = null;

function createWindow() {
  const bounds = store.get('windowBounds');
  mainWindow = new BrowserWindow({
    width: bounds.width || 1280,
    height: bounds.height || 840,
    minWidth: 900,
    minHeight: 600,
    title: '译览',
    backgroundColor: '#0f1419',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      webviewTag: true,
    },
  });

  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));

  mainWindow.once('ready-to-show', () => {
    mainWindow.show();
  });

  mainWindow.on('close', () => {
    if (!mainWindow) return;
    const { width, height } = mainWindow.getBounds();
    store.set('windowBounds', { width, height });
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    // Let the renderer decide how to open links; deny OS popup by default.
    if (url.startsWith('http')) {
      mainWindow?.webContents.send('open-external-url', url);
    }
    return { action: 'deny' };
  });
}

function buildMenu() {
  const isMac = process.platform === 'darwin';
  const template = [
    ...(isMac
      ? [{
          label: app.name,
          submenu: [
            { role: 'about' },
            { type: 'separator' },
            { role: 'quit' },
          ],
        }]
      : []),
    {
      label: '文件',
      submenu: [
        {
          label: '新建标签页',
          accelerator: 'CmdOrCtrl+T',
          click: () => mainWindow?.webContents.send('menu-new-tab'),
        },
        {
          label: '新建隐私标签页',
          accelerator: 'CmdOrCtrl+Shift+N',
          click: () => mainWindow?.webContents.send('menu-new-private-tab'),
        },
        {
          label: '关闭标签页',
          accelerator: 'CmdOrCtrl+W',
          click: () => mainWindow?.webContents.send('menu-close-tab'),
        },
        { type: 'separator' },
        isMac ? { role: 'close' } : { role: 'quit', label: '退出' },
      ],
    },
    {
      label: '编辑',
      submenu: [
        { role: 'undo', label: '撤销' },
        { role: 'redo', label: '重做' },
        { type: 'separator' },
        { role: 'cut', label: '剪切' },
        { role: 'copy', label: '复制' },
        { role: 'paste', label: '粘贴' },
        { role: 'selectAll', label: '全选' },
      ],
    },
    {
      label: '视图',
      submenu: [
        { role: 'reload', label: '重新加载界面' },
        { role: 'toggleDevTools', label: '开发者工具' },
        { type: 'separator' },
        { role: 'resetZoom', label: '实际大小' },
        { role: 'zoomIn', label: '放大' },
        { role: 'zoomOut', label: '缩小' },
        { type: 'separator' },
        { role: 'togglefullscreen', label: '全屏' },
      ],
    },
    {
      label: '帮助',
      submenu: [
        {
          label: '打开 YouTube',
          click: () => mainWindow?.webContents.send('menu-open-youtube'),
        },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

app.whenReady().then(() => {
  buildMenu();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

// ---- Settings / bookmarks IPC ----

ipcMain.handle('settings:get', () => ({
  provider: store.get('provider'),
  apiKey: store.get('apiKey'),
  model: store.get('model'),
  targetLang: store.get('targetLang'),
}));

ipcMain.handle('settings:set', (_event, patch) => {
  const allowed = ['provider', 'apiKey', 'model', 'targetLang'];
  for (const key of allowed) {
    if (Object.prototype.hasOwnProperty.call(patch, key)) {
      store.set(key, patch[key]);
    }
  }
  return true;
});

ipcMain.handle('bookmarks:list', () => store.get('bookmarks') || []);

ipcMain.handle('bookmarks:set', (_event, bookmarks) => {
  store.set('bookmarks', Array.isArray(bookmarks) ? bookmarks : []);
  return true;
});

ipcMain.handle('shell:openExternal', (_event, url) => {
  if (typeof url === 'string' && /^https?:\/\//i.test(url)) {
    return shell.openExternal(url);
  }
  return false;
});

ipcMain.handle('app:getGuestPreloadPath', () => path.join(__dirname, 'guest-preload.js'));

ipcMain.handle('app:getVersion', () => app.getVersion());

// ---- Network helpers (main process = no CORS) ----

ipcMain.handle('net:fetchText', async (_event, url, headers = {}) => {
  if (typeof url !== 'string' || !/^https?:\/\//i.test(url)) {
    return { ok: false, status: -1, body: '' };
  }
  try {
    const res = await fetch(url, {
      headers: {
        'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        ...(headers && typeof headers === 'object' ? headers : {}),
      },
    });
    const body = await res.text();
    return { ok: res.ok, status: res.status, body };
  } catch (err) {
    return { ok: false, status: -1, body: String(err?.message || err) };
  }
});

const INNERTUBE_CLIENTS = [
  {
    ua: 'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12) gzip',
    headers: { 'X-Youtube-Client-Name': '28', 'X-Youtube-Client-Version': '1.65.10' },
    client: {
      clientName: 'ANDROID_VR',
      clientVersion: '1.65.10',
      androidSdkVersion: 32,
      osName: 'Android',
      osVersion: '12',
      hl: 'en',
      gl: 'US',
    },
  },
  {
    ua: 'com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip',
    headers: { 'X-Youtube-Client-Name': '3', 'X-Youtube-Client-Version': '20.10.38' },
    client: {
      clientName: 'ANDROID',
      clientVersion: '20.10.38',
      androidSdkVersion: 34,
      osName: 'Android',
      osVersion: '14',
      hl: 'en',
      gl: 'US',
    },
  },
  {
    ua: 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
    headers: { 'X-Youtube-Client-Name': '5', 'X-Youtube-Client-Version': '20.10.4' },
    client: {
      clientName: 'IOS',
      clientVersion: '20.10.4',
      deviceMake: 'Apple',
      deviceModel: 'iPhone16,2',
      osName: 'iPhone',
      osVersion: '18.3.2.22D82',
      hl: 'en',
      gl: 'US',
    },
  },
  {
    ua: 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version',
    headers: {},
    client: {
      clientName: 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
      clientVersion: '2.0',
      hl: 'en',
      gl: 'US',
    },
    thirdParty: { embedUrl: 'https://www.youtube.com' },
  },
];

ipcMain.handle('net:fetchInnerTubeTracks', async (_event, videoID) => {
  if (typeof videoID !== 'string' || !/^[A-Za-z0-9_-]{10,12}$/.test(videoID)) {
    return [];
  }
  for (const c of INNERTUBE_CLIENTS) {
    try {
      const res = await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': c.ua,
          ...c.headers,
        },
        body: JSON.stringify({
          context: {
            client: c.client,
            ...(c.thirdParty ? { thirdParty: c.thirdParty } : {}),
          },
          videoId: videoID,
          contentCheckOk: true,
          racyCheckOk: true,
        }),
      });
      if (!res.ok) continue;
      const root = await res.json();
      const tracks = root?.captions?.playerCaptionsTracklistRenderer?.captionTracks;
      if (Array.isArray(tracks) && tracks.length) return tracks;
    } catch {
      // try next client
    }
  }
  return [];
});
