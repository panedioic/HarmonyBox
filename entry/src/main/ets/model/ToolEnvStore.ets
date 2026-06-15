import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

export interface Box64Env {
  BOX64_LOG: string;            // '0' | '1' | '2' | '3'
  BOX64_NOBANNER: string;       // '0' | '1'
  BOX64_DYNAREC: string;        // '0' | '1'
  BOX64_LD_LIBRARY_PATH: string;
  customEnv: string;            // 自定义,KEY=VALUE 多行
}

export interface UiPrefs {
  scale: number;  // 1.0 / 1.25 / 1.5 / 2.0 / 3.0
  useNativeDecor: boolean;
}

const FILE_NAME: string = 'tool_env.json';

interface StoreFile {
  box64: Box64Env;
  ui?: UiPrefs;
}

export class ToolEnvStore {
  static defaults(): Box64Env {
    return {
      BOX64_LOG: '1',
      BOX64_NOBANNER: '0',
      BOX64_DYNAREC: '1',
      BOX64_LD_LIBRARY_PATH: '',
      customEnv: ''
    } as Box64Env;
  }

  static getPath(ctx: common.Context): string {
    return `${ctx.filesDir}/${FILE_NAME}`;
  }

  static loadBox64(ctx: common.Context): Box64Env {
    const path: string = ToolEnvStore.getPath(ctx);
    try {
      if (!fs.accessSync(path)) {
        return ToolEnvStore.defaults();
      }
      const data = JSON.parse(fs.readTextSync(path)) as StoreFile;
      const merged: Box64Env = ToolEnvStore.defaults();
      const src: Box64Env | undefined = data.box64;
      if (src) {
        if (typeof src.BOX64_LOG === 'string') merged.BOX64_LOG = src.BOX64_LOG;
        if (typeof src.BOX64_NOBANNER === 'string') merged.BOX64_NOBANNER = src.BOX64_NOBANNER;
        if (typeof src.BOX64_DYNAREC === 'string') merged.BOX64_DYNAREC = src.BOX64_DYNAREC;
        if (typeof src.BOX64_LD_LIBRARY_PATH === 'string') merged.BOX64_LD_LIBRARY_PATH = src.BOX64_LD_LIBRARY_PATH;
        if (typeof src.customEnv === 'string') merged.customEnv = src.customEnv;
      }
      return merged;
    } catch (e) {
      console.error(`ToolEnvStore.loadBox64 failed: ${JSON.stringify(e)}`);
      return ToolEnvStore.defaults();
    }
  }

  static saveBox64(ctx: common.Context, env: Box64Env): void {
    const path: string = ToolEnvStore.getPath(ctx);
    try {
      const data: StoreFile = { box64: env };
      const json: string = JSON.stringify(data, null, 2);
      const file = fs.openSync(
        path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
      );
      try {
        fs.writeSync(file.fd, json);
      } finally {
        fs.closeSync(file.fd);
      }
    } catch (e) {
      console.error(`ToolEnvStore.saveBox64 failed: ${JSON.stringify(e)}`);
    }
  }

  static defaultUiPrefs(): UiPrefs {
    return { scale: 1.0, useNativeDecor: true } as UiPrefs;
  }

  static loadUiPrefs(ctx: common.Context): UiPrefs {
    const path: string = ToolEnvStore.getPath(ctx);
    try {
      if (!fs.accessSync(path)) return ToolEnvStore.defaultUiPrefs();
      const data = JSON.parse(fs.readTextSync(path)) as StoreFile;
      const merged: UiPrefs = ToolEnvStore.defaultUiPrefs();
      if (data.ui) {
        if (typeof data.ui.scale === 'number' && data.ui.scale > 0) {
          merged.scale = data.ui.scale;
        }
        if (typeof data.ui.useNativeDecor === 'boolean') {
          merged.useNativeDecor = data.ui.useNativeDecor;
        }
      }
      return merged;
    } catch (e) {
      console.error(`loadUiPrefs failed: ${JSON.stringify(e)}`);
      return ToolEnvStore.defaultUiPrefs();
    }
  }

  static saveUiPrefs(ctx: common.Context, prefs: UiPrefs): void {
    const path: string = ToolEnvStore.getPath(ctx);
    try {
      let existing: StoreFile;
      if (fs.accessSync(path)) {
        existing = JSON.parse(fs.readTextSync(path)) as StoreFile;
      } else {
        existing = { box64: ToolEnvStore.defaults() } as StoreFile;
      }
      existing.ui = prefs;
      const json: string = JSON.stringify(existing, null, 2);
      const file = fs.openSync(
        path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
      );
      try {
        fs.writeSync(file.fd, json);
      } finally {
        fs.closeSync(file.fd);
      }
    } catch (e) {
      console.error(`saveUiPrefs failed: ${JSON.stringify(e)}`);
    }
  }
}