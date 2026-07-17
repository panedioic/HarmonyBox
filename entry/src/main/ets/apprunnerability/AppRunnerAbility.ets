import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { WindowManagerService } from '../service/WindowManagerService';
import { ProcessManagerService } from '../service/ProcessManagerService';
import { WaylandService } from '../service/WaylandService';
import { AppRegistry } from '../model/AppRegistry';
import { LaunchMode } from '../model/AppInfo';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HBox_Ability_AppRunner';

export default class AppRunnerAbility extends UIAbility {
  private instanceId: string = '';
  private appName: string = '';
  private appId: string = '';
  private clientId: string = '';
  private shortcutAppId: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const params: Record<string, Object> = (want.parameters ?? {}) as Record<string, Object>;
    this.instanceId    = (params.instanceId    as string) ?? '';
    this.appName       = (params.appName       as string) ?? '';
    this.appId         = (params.appId         as string) ?? '';
    this.clientId      = (params.clientId      as string) ?? '';
    this.shortcutAppId = (params.shortcutAppId as string) ?? '';

    hilog.info(0x0000, TAG,
      `[AppRunnerAbility] onCreate `
        + `inst=${this.instanceId} name=${this.appName} appId=${this.appId} `
        + `cid=${this.clientId} shortcut=${this.shortcutAppId}`
    );

    // 服务的 stage 初始化已由 HBoxAbilityStage 保证. 这里补 UI ctx.
    WaylandService.getInstance().initUI(this.context);
    ProcessManagerService.getInstance().initUI(this.context);
    WindowManagerService.getInstance().initUI(this.context);

    // ★ 保证 WMS 里有 instance (幂等; 处理 shortcut/test 场景)
    if (this.instanceId) {
      WindowManagerService.getInstance().ensureInstanceFromAbility(
        this.instanceId, this.appName, this.appId
      );
    }
  }

  async onWindowStageCreate(stage: window.WindowStage): Promise<void> {
    hilog.info(0x0000, TAG,
      `[AppRunnerAbility] onWindowStageCreate inst=${this.instanceId} shortcut=${this.shortcutAppId}`
    );

    const storage: LocalStorage = new LocalStorage();
    storage.setOrCreate<string>('instanceId', this.instanceId);
    storage.setOrCreate<string>('appName',    this.appName);
    storage.setOrCreate<string>('appId',      this.appId);
    storage.setOrCreate<string>('clientId',   this.clientId);

    try {
      await stage.loadContent('pages/AppRunner', storage);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG,
        `[AppRunnerAbility] loadContent failed: ${err.code} ${err.message}`
      );
      return;
    }

    // ★ shortcut 场景: 有 shortcutAppId 但无 instanceId, 现场 launch
    if (this.shortcutAppId && !this.instanceId) {
      const r = await ProcessManagerService.getInstance()
        .launchAppById(this.shortcutAppId, { launchMode: LaunchMode.GUI });
      if (!r.ok) {
        hilog.error(0x0000, TAG,
          `[AppRunnerAbility] shortcut launch failed: ${r.errorMsg}`
        );
        this.context.terminateSelf().catch((): void => { /* ignore */ });
        return;
      }
      this.instanceId = r.instanceId;
      // 更新 storage 里的 instanceId, 让页面拿到最新值
      storage.setOrCreate<string>('instanceId', this.instanceId);

      // 从 registry 取 appName / appId 补齐 storage
      const uiCtx = this.context;
      const app = AppRegistry.getById(uiCtx, this.shortcutAppId);
      if (app) {
        this.appName = app.name;
        this.appId = app.id;
        storage.setOrCreate<string>('appName', app.name);
        storage.setOrCreate<string>('appId',   app.id);
      }
    }

    // ★ 保证 WMS 里有 instance
    if (this.instanceId) {
      WindowManagerService.getInstance().ensureInstanceFromAbility(
        this.instanceId, this.appName, this.appId
      );
    }

    WindowManagerService.getInstance().attachAppRunnerAbility(
      this.instanceId, this.context, stage, storage
    );

    try {
      const mainWin: window.Window = stage.getMainWindowSync();
      if (this.appName) {
        mainWin.setWindowTitle?.(this.appName);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG,
        `[AppRunnerAbility] title set failed: ${err.code} ${err.message}`
      );
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG,
      `[AppRunnerAbility] onWindowStageDestroy inst=${this.instanceId}`
    );
    WindowManagerService.getInstance().detachAppRunnerAbility(this.instanceId);
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG,
      `[AppRunnerAbility] onDestroy inst=${this.instanceId}`
    );
  }

  onForeground(): void {
    hilog.info(0x0000, TAG,
      `[AppRunnerAbility] onForeground inst=${this.instanceId}`
    );
  }

  onBackground(): void {
    hilog.info(0x0000, TAG,
      `[AppRunnerAbility] onBackground inst=${this.instanceId}`
    );
  }
}