import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { WindowManagerService } from '../service/WindowManagerService';
import { ProcessManagerService } from '../service/ProcessManagerService';
import { WaylandService } from '../service/WaylandService';
import { AppRegistry } from '../model/AppRegistry';
import { LaunchMode } from '../model/AppInfo';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HBox_Ability_CliRunner';

export default class CliRunnerAbility extends UIAbility {
  private instanceId: string = '';
  private appName: string = '';
  private appId: string = '';
  private pid: number = 0;
  private shortcutAppId: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const params: Record<string, Object> = (want.parameters ?? {}) as Record<string, Object>;
    this.instanceId    = (params.instanceId    as string) ?? '';
    this.appName       = (params.appName       as string) ?? '';
    this.appId         = (params.appId         as string) ?? '';
    this.pid           = (params.pid           as number) ?? 0;
    this.shortcutAppId = (params.shortcutAppId as string) ?? '';

    hilog.info(0x0000, TAG,
      `[CliRunnerAbility] onCreate `
        + `inst=${this.instanceId} name=${this.appName} appId=${this.appId} `
        + `pid=${this.pid} shortcut=${this.shortcutAppId}`
    );

    WaylandService.getInstance().initUI(this.context);
    ProcessManagerService.getInstance().initUI(this.context);
    WindowManagerService.getInstance().setFallbackContext(this.context);   // ★

    // ★ 保证 WMS 里有 instance (幂等; 处理 shortcut/test 场景)
    if (this.instanceId) {
      WindowManagerService.getInstance().ensureInstanceFromAbility(
        this.instanceId, this.appName, this.appId
      );
    }
  }

  async onWindowStageCreate(stage: window.WindowStage): Promise<void> {
    hilog.info(0x0000, TAG,
      `[CliRunnerAbility] onWindowStageCreate inst=${this.instanceId} shortcut=${this.shortcutAppId}`
    );

    const storage: LocalStorage = new LocalStorage();
    storage.setOrCreate<string>('instanceId', this.instanceId);
    storage.setOrCreate<string>('appName',    this.appName);
    storage.setOrCreate<string>('appId',      this.appId);
    storage.setOrCreate<number>('cliPid',     this.pid);

    try {
      await stage.loadContent('pages/CliRunner', storage);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG,
        `[CliRunnerAbility] loadContent failed: ${err.code} ${err.message}`
      );
      return;
    }

    // ★ shortcut 场景
    if (this.shortcutAppId && !this.instanceId) {
      const app = AppRegistry.getById(this.context, this.shortcutAppId);
      if (!app) {
        hilog.error(0x0000, TAG, `[CliRunnerAbility] shortcut app not found: ${this.shortcutAppId}`);
        this.context.terminateSelf().catch((): void => { /* ignore */ });
        return;
      }
      const preAllocId: string = ProcessManagerService.getInstance().allocateInstanceId();
      this.instanceId = preAllocId;
      this.appName    = app.name;
      this.appId      = app.id;
      storage.setOrCreate<string>('instanceId', preAllocId);
      storage.setOrCreate<string>('appName',    app.name);
      storage.setOrCreate<string>('appId',      app.id);
      WindowManagerService.getInstance().ensureInstanceFromAbility(preAllocId, app.name, app.id);
      WindowManagerService.getInstance().attachCliRunnerAbility(
        preAllocId, this.context, stage, storage
      );
      const r = await ProcessManagerService.getInstance().launchAppById(
        this.shortcutAppId,
        { launchMode: LaunchMode.CLI, reuseInstanceId: preAllocId }
      );
      if (!r.ok) {
        hilog.error(0x0000, TAG, `[CliRunnerAbility] shortcut launch failed: ${r.errorMsg}`);
        WindowManagerService.getInstance().destroyInstance(preAllocId);
        return;
      }
      // pid 现在有值, 更新 storage
      this.pid = ProcessManagerService.getInstance().getPidByInstance(preAllocId);
      storage.setOrCreate<number>('cliPid', this.pid);
      try {
        const mainWin: window.Window = stage.getMainWindowSync();
        mainWin.setWindowTitle?.(`${app.name} — 日志`);
      } catch (e) { /* ignore */ }
      return;
    }

    // ─── 常规路径 ───
    if (this.instanceId) {
      WindowManagerService.getInstance().ensureInstanceFromAbility(
        this.instanceId, this.appName, this.appId
      );
    }

    WindowManagerService.getInstance().attachCliRunnerAbility(
      this.instanceId, this.context, stage, storage
    );

    try {
      const mainWin: window.Window = stage.getMainWindowSync();
      const title: string = this.appName ? `${this.appName} — 日志` : '应用日志';
      mainWin.setWindowTitle?.(title);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG,
        `[CliRunnerAbility] title set failed: ${err.code} ${err.message}`
      );
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG,
      `[CliRunnerAbility] onWindowStageDestroy inst=${this.instanceId}`
    );
    WindowManagerService.getInstance().detachCliRunnerAbility(this.instanceId);
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG,
      `[CliRunnerAbility] onDestroy inst=${this.instanceId}`
    );
    WindowManagerService.getInstance().clearFallbackContext(this.context);  // ★
  }

  onForeground(): void {
    hilog.info(0x0000, TAG,
      `[CliRunnerAbility] onForeground inst=${this.instanceId}`
    );
  }

  onBackground(): void {
    hilog.info(0x0000, TAG,
      `[CliRunnerAbility] onBackground inst=${this.instanceId}`
    );
  }
}