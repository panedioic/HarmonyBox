import { AbilityStage } from '@kit.AbilityKit';
import { WaylandService } from '../service/WaylandService';
import { ProcessManagerService } from '../service/ProcessManagerService';
import { WindowManagerService } from '../service/WindowManagerService';

export default class HBoxAbilityStage extends AbilityStage {
  onCreate(): void {
    console.info('[HBoxAbilityStage] onCreate: initializing services...');

    // 顺序: wayland server → procmgr → windowmgr (listener 依赖 wl service)
    const wlOk: boolean = WaylandService.getInstance().initStage(this.context);
    console.info(`[HBoxAbilityStage] wayland ready=${wlOk}`);

    ProcessManagerService.getInstance().initStage(this.context);
    console.info('[HBoxAbilityStage] procmgr initialized');

    WindowManagerService.getInstance().initStage(this.context);
    console.info('[HBoxAbilityStage] windowmgr initialized');

    console.info('[HBoxAbilityStage] onCreate done');
  }
}