import { productViewManager } from '@kit.AppGalleryKit';
import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppInfo } from '../model/AppInfo';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HBox_UI_Svc_Shortcut';

const DEFAULT_ICON_RAWFILE:  string = 'shortcut_icon_default.png';
const DEFAULT_ICON_FILENAME: string = 'shortcut_icon_default.png';

export interface ShortcutOptions {
  /** 未来支持 per-app 自定义图标绝对路径; 当前未实现, 传入也会 fallback 到默认 */
  customIconPath?: string;
}

export interface ShortcutResult {
  ok: boolean;
  error: string;
}

/**
 * 桌面快捷方式服务.
 * - 快捷方式点击后拉起 AppRunnerAbility, 携带 shortcutAppId=app.id
 * - AppRunnerAbility.onWindowStageCreate 的 shortcut 分支会走 launchAppById
 */
export class ShortcutService {
  private static instance: ShortcutService | null = null;

  static getInstance(): ShortcutService {
    if (!ShortcutService.instance) {
      ShortcutService.instance = new ShortcutService();
    }
    return ShortcutService.instance;
  }

  private defaultIconReady: boolean = false;

  /** 为已安装应用创建桌面快捷方式 (系统会弹窗让用户确认) */
  async createShortcutForApp(
    ctx: common.UIAbilityContext,
    app: AppInfo,
    opts?: ShortcutOptions
  ): Promise<ShortcutResult> {
    if (!app || !app.id) {
      return { ok: false, error: '无效的应用' };
    }

    let iconPath: string;
    try {
      iconPath = await this.prepareIconPath(ctx, opts?.customIconPath);
    } catch (e) {
      const err = e as BusinessError;
      return { ok: false, error: `准备图标失败: ${err.code ?? -1} ${err.message ?? e}` };
    }

    const shortcutId: string = `hbox_${app.id}`;
    const label: string = app.name;
    const backgroundIcon: string = '';

    // want.parameters 只能是基础类型
    const params: Record<string, Object> = {};
    params['shortcutAppId'] = app.id;
    params['source']        = 'desktop_pin';

    const want: Want = {
      bundleName:  ctx.abilityInfo.bundleName,
      moduleName:  'entry',
      abilityName: 'AppRunnerAbility',
      parameters:  params
    };

    try {
      const check: productViewManager.CheckShortcutResult =
        await productViewManager.checkPinShortcutPermitted(
          ctx, shortcutId, want, label, iconPath, backgroundIcon
        );
      const tid: string = check.tid ?? '';
      if (!tid) {
        return { ok: false, error: '系统不允许添加此快捷方式 (可能已达上限)' };
      }
      await productViewManager.requestNewPinShortcut(ctx, tid);
      hilog.info(0x0000, TAG, `[ShortcutService] pin request sent for app=${app.id} label=${label}`);
      return { ok: true, error: '' };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, `[ShortcutService] create failed: ${err.code} ${err.message}`);
      return { ok: false, error: `${err.code}: ${err.message}` };
    }
  }

  // =========================================================
  // icon 准备
  // =========================================================

  private async prepareIconPath(
    ctx: common.UIAbilityContext,
    customPath?: string
  ): Promise<string> {
    // 未来: per-app 自定义图标
    if (customPath && customPath.length > 0) {
      try {
        if (fs.accessSync(customPath)) return customPath;
        hilog.warn(0x0000, TAG, `[ShortcutService] customIconPath not accessible, fallback: ${customPath}`);
      } catch (_e) { /* fall through */ }
    }
    return this.ensureDefaultIcon(ctx);
  }

  private async ensureDefaultIcon(ctx: common.UIAbilityContext): Promise<string> {
    const dest: string = `${ctx.filesDir}/${DEFAULT_ICON_FILENAME}`;
    if (this.defaultIconReady) return dest;

    try {
      if (fs.accessSync(dest)) {
        const stat = fs.statSync(dest);
        if (stat.size > 0) {
          this.defaultIconReady = true;
          hilog.info(0x0000, TAG, `[ShortcutService] icon cached: ${dest} size=${stat.size}`);
          return dest;
        }
        hilog.warn(0x0000, TAG, `[ShortcutService] cached icon 0 byte, rewrite`);
      }
    } catch (_e) { /* need to write */ }

    const raw: Uint8Array =
      await ctx.resourceManager.getRawFileContent(DEFAULT_ICON_RAWFILE);
    hilog.info(0x0000, TAG, `[ShortcutService] rawfile loaded: ${raw.byteLength} bytes`);

    const arrayBuffer: ArrayBuffer = raw.buffer.slice(
      raw.byteOffset, raw.byteOffset + raw.byteLength
    ) as ArrayBuffer;

    const file: fs.File = fs.openSync(dest,
      fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, arrayBuffer);
    } finally {
      fs.closeSync(file.fd);
    }

    const finalStat = fs.statSync(dest);
    hilog.info(0x0000, TAG, `[ShortcutService] icon written: ${dest} size=${finalStat.size}`);
    this.defaultIconReady = true;
    return dest;
  }
}