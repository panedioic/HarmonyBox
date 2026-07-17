import { AbilityStage } from '@kit.AbilityKit';
import { WaylandService } from '../service/WaylandService';
import { ProcessManagerService } from '../service/ProcessManagerService';
import { WindowManagerService } from '../service/WindowManagerService';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HBox_Ability_HBoxAbilityStage';

export default class HBoxAbilityStage extends AbilityStage {
  onCreate(): void {
    hilog.info(0x0000, TAG, '[HBoxAbilityStage] onCreate: initializing services...');

    // 顺序: wayland server → procmgr → windowmgr (listener 依赖 wl service)
    const wlOk: boolean = WaylandService.getInstance().initStage(this.context);
    hilog.info(0x0000, TAG, `[HBoxAbilityStage] wayland ready=${wlOk}`);

    ProcessManagerService.getInstance().initStage(this.context);
    hilog.info(0x0000, TAG, '[HBoxAbilityStage] procmgr initialized');

    WindowManagerService.getInstance().initStage(this.context);
    hilog.info(0x0000, TAG, '[HBoxAbilityStage] windowmgr initialized');

    hilog.info(0x0000, TAG, '[HBoxAbilityStage] onCreate done');
  }
}