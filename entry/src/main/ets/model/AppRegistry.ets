import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import {
  AppInfo, AppConfig, RuntimeMode, ExecPathType,
  migrateAppType, migrateExecPathType
} from './AppInfo';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HBox_Model_AppRegistry';

const APPS_DIR:      string = 'apps';
const APP_JSON:      string = 'app.json';
const LEGACY_FILE:   string = 'apps.json';
const LEGACY_BACKUP: string = 'apps.json.migrated';

/** 单个 app.json 落盘格式 (installDir 由目录名重建; type 弃用) */
interface AppJsonFile {
  id: string;
  name: string;
  icon: string;
  runtimeMode: string;
  execPath: string;
  execPathType: string;
  installedAt: number;
  config: AppConfig;
  containerId: string;
}

/** 老 apps.json 结构 (仅迁移用) */
interface LegacyRegistryFile {
  apps: AppInfo[];
}

export class AppRegistry {
  private static migrated: boolean = false;

  // ==============================================================
  //  路径工具
  // ==============================================================
  private static appsRoot(ctx: common.Context): string {
    const dir: string = `${ctx.filesDir}/${APPS_DIR}`;
    try {
      if (!fs.accessSync(dir)) fs.mkdirSync(dir, true);
    } catch (_e) { /* ignore */ }
    return dir;
  }

  private static appDir(ctx: common.Context, appId: string): string {
    return `${AppRegistry.appsRoot(ctx)}/${appId}`;
  }

  // ==============================================================
  //  读: 单个
  // ==============================================================
  private static readAppJson(ctx: common.Context, dirName: string): AppInfo | null {
    const jsonPath: string = `${AppRegistry.appsRoot(ctx)}/${dirName}/${APP_JSON}`;
    try {
      if (!fs.accessSync(jsonPath)) return null;
      const txt: string = fs.readTextSync(jsonPath);
      const raw: AppJsonFile = JSON.parse(txt) as AppJsonFile;
      if (!raw || !raw.name) return null;

      return new AppInfo(
        raw.id || dirName,
        raw.name,
        raw.icon || '📦',
        migrateAppType(''),                        // type 弃用
        (raw.runtimeMode as RuntimeMode) || RuntimeMode.GUI,
        raw.execPath || '',
        migrateExecPathType(raw.execPathType),
        `${APPS_DIR}/${dirName}`,                  // installDir 由目录名重建
        raw.installedAt || Date.now(),
        raw.config || { envVars: '', args: '' } as AppConfig,
        raw.containerId || ''
      );
    } catch (e) {
      hilog.warn(0x0000, TAG,
        `readAppJson(${dirName}) failed: ${(e as Error).message}`);
      return null;
    }
  }

  // ==============================================================
  //  写: 单个
  // ==============================================================
  static save(ctx: common.Context, app: AppInfo): boolean {
    if (!app.id) {
      hilog.error(0x0000, TAG, `save: app.id is empty`);
      return false;
    }
    const dir: string = AppRegistry.appDir(ctx, app.id);
    try {
      if (!fs.accessSync(dir)) fs.mkdirSync(dir, true);
    } catch (e) {
      hilog.error(0x0000, TAG, `save mkdir failed: ${(e as Error).message}`);
      return false;
    }

    const path: string = `${dir}/${APP_JSON}`;
    const data: AppJsonFile = {
      id:           app.id,
      name:         app.name,
      icon:         app.icon || '📦',
      runtimeMode:  app.runtimeMode,
      execPath:     app.execPath,
      execPathType: app.execPathType,
      installedAt:  app.installedAt,
      config:       app.config,
      containerId:  app.containerId
    };
    try {
      const f: fs.File = fs.openSync(path,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(data, null, 2));
      } finally {
        fs.closeSync(f);
      }
      return true;
    } catch (e) {
      hilog.error(0x0000, TAG, `save write failed: ${(e as Error).message}`);
      return false;
    }
  }

  // ==============================================================
  //  扫描: 全部
  // ==============================================================
  static list(ctx: common.Context): AppInfo[] {
    AppRegistry.runMigrationIfNeeded(ctx);

    const root: string = AppRegistry.appsRoot(ctx);
    const out: AppInfo[] = [];
    let names: string[] = [];
    try {
      names = fs.listFileSync(root);
    } catch (_e) { return out; }

    for (const name of names) {
      const dir: string = `${root}/${name}`;
      try {
        const st = fs.statSync(dir);
        if (!st.isDirectory()) continue;
      } catch (_e) { continue; }

      const app: AppInfo | null = AppRegistry.readAppJson(ctx, name);
      if (app) out.push(app);
    }

    // 按 installedAt 降序 (新装的排前面)
    out.sort((a: AppInfo, b: AppInfo): number => b.installedAt - a.installedAt);
    return out;
  }

  /** @deprecated 用 list() 代替; 保留是为了兼容旧调用 */
  static load(ctx: common.Context): AppInfo[] {
    return AppRegistry.list(ctx);
  }

  // ==============================================================
  //  查: 单个
  // ==============================================================
  static getById(ctx: common.Context, appId: string): AppInfo | null {
    if (!appId) return null;
    AppRegistry.runMigrationIfNeeded(ctx);
    return AppRegistry.readAppJson(ctx, appId);
  }

  // ==============================================================
  //  add / remove / update (返回全表, 兼容旧调用方)
  // ==============================================================
  static add(ctx: common.Context, app: AppInfo): AppInfo[] {
    AppRegistry.save(ctx, app);
    return AppRegistry.list(ctx);
  }

  /**
   * 只清除 app.json (可能顺带清空目录);
   * 应用文件本身由 InstallService.uninstall 负责.
   */
  static remove(ctx: common.Context, appId: string): AppInfo[] {
    const dir: string = AppRegistry.appDir(ctx, appId);
    const jsonPath: string = `${dir}/${APP_JSON}`;

    try {
      if (fs.accessSync(jsonPath)) fs.unlinkSync(jsonPath);
    } catch (_e) { /* ignore */ }

    // 目录已空则一并删掉 (uninstall 未跑或失败时兜底)
    try {
      if (fs.accessSync(dir)) {
        const entries: string[] = fs.listFileSync(dir);
        if (entries.length === 0) fs.rmdirSync(dir);
      }
    } catch (_e) { /* ignore */ }

    return AppRegistry.list(ctx);
  }

  static update(ctx: common.Context, updated: AppInfo): AppInfo[] {
    AppRegistry.save(ctx, updated);
    return AppRegistry.list(ctx);
  }

  // ==============================================================
  //  一次性迁移: 老 apps.json → 每目录 app.json
  // ==============================================================
  private static runMigrationIfNeeded(ctx: common.Context): void {
    if (AppRegistry.migrated) return;
    AppRegistry.migrated = true;   // 无论成败只跑一次 (进程生命周期内)

    const legacyPath: string = `${ctx.filesDir}/${LEGACY_FILE}`;
    try {
      if (!fs.accessSync(legacyPath)) return;
    } catch (_e) { return; }

    hilog.info(0x0000, TAG, `[migrate] found ${LEGACY_FILE}, migrating...`);
    let list: AppInfo[] = [];
    try {
      const txt: string = fs.readTextSync(legacyPath);
      const data: LegacyRegistryFile = JSON.parse(txt) as LegacyRegistryFile;
      list = data.apps || [];
    } catch (e) {
      hilog.error(0x0000, TAG,
        `[migrate] parse legacy failed: ${(e as Error).message}`);
      return;
    }

    let ok: number = 0;
    for (const a of list) {
      if (!a.id) continue;
      const dir: string = AppRegistry.appDir(ctx, a.id);
      try {
        if (!fs.accessSync(dir)) {
          hilog.warn(0x0000, TAG, `[migrate] skip ${a.id}: dir missing`);
          continue;
        }
      } catch (_e) { continue; }

      // 老数据没有 execPathType 字段, 默认 APP_RELATIVE (保持原行为)
      const json: AppJsonFile = {
        id:           a.id,
        name:         a.name,
        icon:         a.icon || '📦',
        runtimeMode:  a.runtimeMode || RuntimeMode.GUI,
        execPath:     a.execPath,
        execPathType: a.execPathType || ExecPathType.APP_RELATIVE,
        installedAt:  a.installedAt || Date.now(),
        config:       a.config || { envVars: '', args: '' } as AppConfig,
        containerId:  a.containerId || ''
      };
      try {
        const f: fs.File = fs.openSync(`${dir}/${APP_JSON}`,
          fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(f.fd, JSON.stringify(json, null, 2));
        } finally {
          fs.closeSync(f);
        }
        ok++;
      } catch (e) {
        hilog.warn(0x0000, TAG,
          `[migrate] write ${a.id}/app.json failed: ${(e as Error).message}`);
      }
    }
    hilog.info(0x0000, TAG, `[migrate] wrote ${ok}/${list.length} app.json files`);

    // 保留老文件作备份 (rename 而不是 unlink)
    try {
      const backup: string = `${ctx.filesDir}/${LEGACY_BACKUP}`;
      try { if (fs.accessSync(backup)) fs.unlinkSync(backup); } catch (_e) { /* ignore */ }
      fs.renameSync(legacyPath, backup);
      hilog.info(0x0000, TAG, `[migrate] legacy backed up to ${LEGACY_BACKUP}`);
    } catch (e) {
      hilog.warn(0x0000, TAG,
        `[migrate] backup legacy failed: ${(e as Error).message}`);
    }
  }
}