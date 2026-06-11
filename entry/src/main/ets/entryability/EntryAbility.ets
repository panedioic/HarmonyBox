import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    AppStorage.setOrCreate<window.WindowStage>('windowStage', windowStage);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        console.error(`loadContent failed: ${err.code}, ${err.message}`);
      }
    });
  }

  onWindowStageDestroy(): void {
    AppStorage.delete('windowStage');
  }
}