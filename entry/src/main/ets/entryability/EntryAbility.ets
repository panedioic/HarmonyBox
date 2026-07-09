import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    AppStorage.setOrCreate<window.WindowStage>('windowStage', windowStage);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        console.error(`loadContent failed: ${err.code}, ${err.message}`);
      }
    });

    // 沉浸式
    windowStage.getMainWindow((err: BusinessError, data) => {
      if (err) {
        // To do sth.
      }
      let windowClass = data;
      // 存储windowClass
      AppStorage.setOrCreate('windowClass', windowClass);
      try {
        // 设置标题栏不可见
        windowClass.setWindowDecorVisible(false);
        // 设置标题栏高度
        windowClass.setWindowDecorHeight(56);
      } catch (error) {
        // TODO: Implement error handling.
      }
    });
  }

  onWindowStageDestroy(): void {
    AppStorage.delete('windowStage');
  }
}