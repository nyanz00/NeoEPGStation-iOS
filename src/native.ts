import { NativeModules } from 'react-native';

export interface Connection {
  url: string;
}

interface NeoNativeModule {
  loadConnection(): Promise<Connection | null>;
  saveConnection(connection: Connection): Promise<Connection>;
  play(options: {
    url: string;
    title: string;
    networkCaching: number;
  }): Promise<void>;
}

export const native = NativeModules.NeoNative as NeoNativeModule;
