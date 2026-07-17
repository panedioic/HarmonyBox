import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { WindowManagerService } from '../service/WindowManagerService';
import { ProcessManagerService } from '../service/ProcessManagerService';
import { WaylandService } from '../service/WaylandService';

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

    console.info(
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
    console.info(`[AppRunnerAbility] onWindowStageCreate inst=${this.instanceId}`);

    const storage: LocalStorage = new LocalStorage();
    storage.setOrCreate<string>('instanceId', this.instanceId);
    storage.setOrCreate<string>('appName',    this.appName);
    storage.setOrCreate<string>('appId',      this.appId);
    storage.setOrCreate<string>('clientId',   this.clientId);

    try {
      await stage.loadContent('pages/AppRunner', storage);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[AppRunnerAbility] loadContent failed: ${err.code} ${err.message}`);
      return;
    }

    WindowManagerService.getInstance().attachAppRunnerAbility(
      this.instanceId, this.context, stage
    );

    try {
      const mainWin: window.Window = stage.getMainWindowSync();
      if (this.appName) {
        mainWin.setWindowTitle?.(this.appName);
      }
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[AppRunnerAbility] title set failed: ${err.code} ${err.message}`);
    }
  }

  onWindowStageDestroy(): void {
    console.info(`[AppRunnerAbility] onWindowStageDestroy inst=${this.instanceId}`);
    WindowManagerService.getInstance().detachAppRunnerAbility(this.instanceId);
  }

  onDestroy(): void {
    console.info(`[AppRunnerAbility] onDestroy inst=${this.instanceId}`);
  }

  onForeground(): void {
    console.info(`[AppRunnerAbility] onForeground inst=${this.instanceId}`);
  }

  onBackground(): void {
    console.info(`[AppRunnerAbility] onBackground inst=${this.instanceId}`);
  }
}