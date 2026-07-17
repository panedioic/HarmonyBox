import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { WaylandService } from '../service/WaylandService';
import { ProcessManagerService } from '../service/ProcessManagerService';
import { WindowManagerService } from '../service/WindowManagerService';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[EntryAbility] onCreate');
    // Stage 已启动 native 服务, 这里只补充 uiCtx (供 launcher 内部 startAbility 用)
    WaylandService.getInstance().initUI(this.context);
    ProcessManagerService.getInstance().initUI(this.context);
    WindowManagerService.getInstance().initUI(this.context);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // launcher 已运行时再次被拉起 (比如从系统 shortcut), 保证 uiCtx 引用最新的 EntryAbility context
    console.info('[EntryAbility] onNewWant');
    WaylandService.getInstance().initUI(this.context);
    ProcessManagerService.getInstance().initUI(this.context);
    WindowManagerService.getInstance().initUI(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    AppStorage.setOrCreate<window.WindowStage>('windowStage', windowStage);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        console.error(`loadContent failed: ${err.code}, ${err.message}`);
      }
    });

    // 沉浸式
    windowStage.getMainWindow((err: BusinessError, data) => {
      if (err) return;
      const windowClass = data;
      AppStorage.setOrCreate('windowClass', windowClass);
      try {
        windowClass.setWindowDecorVisible(false);
        windowClass.setWindowDecorHeight(56);
      } catch (_e) { /* ignore */ }
    });
  }

  onWindowStageDestroy(): void {
    AppStorage.delete('windowStage');
  }

  onDestroy(): void {
    console.info('[EntryAbility] onDestroy');
    // 不主动 shutdown wayland: AppRunnerAbility 可能还在跑
    // wayland server 生命周期已挪到 HBoxAbilityStage
  }
}