import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { WindowManagerService } from '../service/WindowManagerService';
import { ProcessManagerService } from '../service/ProcessManagerService';
import { WaylandService } from '../service/WaylandService';

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

    console.info(
      `[CliRunnerAbility] onCreate `
        + `inst=${this.instanceId} name=${this.appName} appId=${this.appId} `
        + `pid=${this.pid} shortcut=${this.shortcutAppId}`
    );

    WaylandService.getInstance().initUI(this.context);
    ProcessManagerService.getInstance().initUI(this.context);
    WindowManagerService.getInstance().initUI(this.context);
  }

  async onWindowStageCreate(stage: window.WindowStage): Promise<void> {
    console.info(`[CliRunnerAbility] onWindowStageCreate inst=${this.instanceId}`);

    try {
      await stage.loadContent('pages/CliRunner');
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[CliRunnerAbility] loadContent failed: ${err.code} ${err.message}`);
      return;
    }

    WindowManagerService.getInstance().attachCliRunnerAbility(
      this.instanceId, this.context, stage
    );

    try {
      const mainWin: window.Window = stage.getMainWindowSync();
      mainWin.setWindowBackgroundColor('#FF1E1E1E');
      const title: string = this.appName ? `${this.appName} — 日志` : '应用日志';
      mainWin.setWindowTitle?.(title);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[CliRunnerAbility] window customize failed: ${err.code} ${err.message}`);
    }
  }

  onWindowStageDestroy(): void {
    console.info(`[CliRunnerAbility] onWindowStageDestroy inst=${this.instanceId}`);
    WindowManagerService.getInstance().detachCliRunnerAbility(this.instanceId);
  }

  onDestroy(): void {
    console.info(`[CliRunnerAbility] onDestroy inst=${this.instanceId}`);
  }

  onForeground(): void {
    console.info(`[CliRunnerAbility] onForeground inst=${this.instanceId}`);
  }

  onBackground(): void {
    console.info(`[CliRunnerAbility] onBackground inst=${this.instanceId}`);
  }
}