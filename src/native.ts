import { NativeModules } from 'react-native';

export interface Connection {
  url: string;
}

interface NeoNativeModule {
  uiSmoke?: string;
  reportUIReady(value: {
    stage: string;
    route: string;
    shortcuts: string[];
    theme: string;
    recordCount: number;
    sidebarWidth?: number | null;
  }): Promise<void>;
  loadNavigation(): Promise<string[] | null>;
  saveNavigation(items: string[]): Promise<void>;
  loadConnection(): Promise<Connection | null>;
  saveConnection(connection: Connection): Promise<Connection>;
  play(options: {
    url: string;
    title: string;
    networkCaching: number;
  }): Promise<void>;
}

export const native = NativeModules.NeoNative as NeoNativeModule;
