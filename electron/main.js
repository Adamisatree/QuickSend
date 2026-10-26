const { app, BrowserWindow, dialog } = require('electron');

process.env.PORT = process.env.PORT || '4321';
const server = require('../src/server');

app.disableHardwareAcceleration();
app.on('window-all-closed', () => app.quit());
app.on('before-quit', () => {
  if (server.listening) server.close();
});

async function openWindow() {
  const window = new BrowserWindow({
    width: 1180,
    height: 850,
    minWidth: 360,
    minHeight: 620,
    title: 'QuickSend',
    autoHideMenuBar: true,
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith('http://127.0.0.1:')) event.preventDefault();
  });
  const port = server.address()?.port || Number(process.env.PORT) || 4321;
  await window.loadURL(`http://127.0.0.1:${port}`);
}

app.whenReady().then(() => {
  if (server.listening) openWindow().catch(showStartupError);
  else {
    server.once('listening', () => openWindow().catch(showStartupError));
    server.once('error', showStartupError);
  }
});
function showStartupError(error) {
  dialog.showErrorBox('QuickSend 启动失败', `${error.message}\n请关闭占用端口的程序后重试。`);
  app.quit();
}
