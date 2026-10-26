import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.quicksend.lan',
  appName: 'QuickSend',
  webDir: 'public',
  android: {
    allowMixedContent: true,
  },
};

export default config;
