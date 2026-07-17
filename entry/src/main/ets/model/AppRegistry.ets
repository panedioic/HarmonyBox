import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { AppInfo, AppType, AppConfig, RuntimeMode, migrateAppType } from './AppInfo';

const REGISTRY_FILE: string = 'apps.json';

interface RegistryFile {
  apps: AppInfo[];
}

export class AppRegistry {
  static getRegistryPath(context: common.Context): string {
    return `${context.filesDir}/${REGISTRY_FILE}`;
  }

  static load(context: common.Context): AppInfo[] {
    const path: string = AppRegistry.getRegistryPath(context);
    try {
      if (!fs.accessSync(path)) {
        return [];
      }
      const content: string = fs.readTextSync(path);
      const data = JSON.parse(content) as RegistryFile;
      const list: AppInfo[] = data.apps || [];
      return list.map((a: AppInfo) => new AppInfo(
        a.id, a.name, a.icon,
        migrateAppType(a.type as string),
        a.runtimeMode || RuntimeMode.GUI,
        a.execPath, a.installDir, a.installedAt,
        a.config || { envVars: '', args: '' } as AppConfig,
        a.containerId || ''
      ));
    } catch (e) {
      console.error(`AppRegistry.load failed: ${JSON.stringify(e)}`);
      return [];
    }
  }

  static save(context: common.Context, apps: AppInfo[]): void {
    const path: string = AppRegistry.getRegistryPath(context);
    try {
      const data: RegistryFile = { apps };
      const json: string = JSON.stringify(data, null, 2);
      const file = fs.openSync(
        path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
      );
      try {
        fs.writeSync(file.fd, json);
      } finally {
        fs.closeSync(file.fd);
      }
    } catch (e) {
      console.error(`AppRegistry.save failed: ${JSON.stringify(e)}`);
    }
  }

  static add(context: common.Context, app: AppInfo): AppInfo[] {
    const apps: AppInfo[] = AppRegistry.load(context);
    apps.push(app);
    AppRegistry.save(context, apps);
    return apps;
  }

  static remove(context: common.Context, appId: string): AppInfo[] {
    const apps: AppInfo[] = AppRegistry.load(context);
    const filtered: AppInfo[] = apps.filter((a: AppInfo) => a.id !== appId);
    AppRegistry.save(context, filtered);
    return filtered;
  }

  static update(context: common.Context, updated: AppInfo): AppInfo[] {
    const apps: AppInfo[] = AppRegistry.load(context);
    const idx: number = apps.findIndex((a: AppInfo): boolean => a.id === updated.id);
    if (idx < 0) {
      return apps;
    }
    apps[idx] = updated;
    AppRegistry.save(context, apps);
    return apps;
  }

  static getById(context: common.Context, appId: string): AppInfo | null {
    if (!appId) return null;
    const apps: AppInfo[] = AppRegistry.load(context);
    for (const a of apps) {
      if (a.id === appId) return a;
    }
    return null;
  }
}