import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { WaylandService } from '../service/WaylandService';
import { ProcessManagerService } from '../service/ProcessManagerService';
import { WindowManagerService } from '../service/WindowManagerService';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HBox_Ability_Enter';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, '[EntryAbility] onCreate');
    // Stage 已启动 native 服务, 这里只补充 uiCtx (供 launcher 内部 startAbility 用)
    WaylandService.getInstance().initUI(this.context);
    ProcessManagerService.getInstance().initUI(this.context);
    WindowManagerService.getInstance().bindLauncherContext(this.context);   // ★
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // launcher 已运行时再次被拉起 (比如从系统 shortcut), 保证 uiCtx 引用最新的 EntryAbility context
    hilog.info(0x0000, TAG, '[EntryAbility] onNewWant');
    WaylandService.getInstance().initUI(this.context);
    ProcessManagerService.getInstance().initUI(this.context);
    WindowManagerService.getInstance().bindLauncherContext(this.context);   // ★
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    AppStorage.setOrCreate<window.WindowStage>('windowStage', windowStage);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, `loadContent failed: ${err.code}, ${err.message}`);
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
    hilog.info(0x0000, TAG, '[EntryAbility] onDestroy');
    // 不主动 shutdown wayland: AppRunnerAbility 可能还在跑
    // wayland server 生命周期已挪到 HBoxAbilityStage
    WindowManagerService.getInstance().unbindLauncherContext(this.context);  // ★
  }
}