import { window, display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Theme, PageType } from '../common/Theme';
import { AppInfo } from '../model/AppInfo';
import { AppRegistry } from '../model/AppRegistry';
import { runningWindows } from '../model/RunningWindow';
import { Sidebar } from '../components/Sidebar';
import { LibraryPage } from '../components/LibraryPage';
import { InstallPage } from '../components/InstallPage';
import { SettingsPage } from '../components/SettingsPage';
import { FilesPage } from '../components/FilesPage';
import { InstallService } from '../service/InstallService';

@Entry
@Component
struct Index {
  @State currentPage: string = PageType.LIBRARY;
  @State installedApps: AppInfo[] = [];

  aboutToAppear(): void {
    const ctx = getContext(this) as common.Context;
    this.installedApps = AppRegistry.load(ctx);
  }

  launchApp = (name: string): void => {
    this.openAppWindow(name);
  }

  addApp = (app: AppInfo): void => {
    const ctx = getContext(this) as common.Context;
    const list = AppRegistry.add(ctx, app);
    this.installedApps = list;
    this.currentPage = PageType.LIBRARY;
  }

  deleteApp = (app: AppInfo): void => {
    const ctx = getContext(this) as common.Context;

    // 1. 如果该应用窗口正在运行,先关闭
    const running = runningWindows.get(app.name);
    if (running) {
      try {
        running.destroyWindow();
      } catch (e) {
        console.error(`destroy window failed: ${JSON.stringify(e)}`);
      }
      runningWindows.remove(app.name);
    }

    // 2. 删除沙箱目录
    try {
      InstallService.uninstall(ctx, app.installDir);
    } catch (e) {
      console.error(`uninstall failed: ${JSON.stringify(e)}`);
      // 即使目录删除失败,也继续清理注册表,避免 UI 卡死
    }

    // 3. 更新注册表
    this.installedApps = AppRegistry.remove(ctx, app.id);
  }

  async openAppWindow(name: string): Promise<void> {
    try {
      const existing = runningWindows.get(name);
      if (existing) {
        await existing.showWindow();
        await existing.raiseToAppTop?.();
        return;
      }

      const windowStage = AppStorage.get<window.WindowStage>('windowStage');
      if (!windowStage) {
        console.error('windowStage not ready');
        return;
      }

      const mainWindow = windowStage.getMainWindowSync();

      AppStorage.setOrCreate<string>('currentAppName', name);

      const subWin = await mainWindow.createSubWindowWithOptions(`app_${name}_${Date.now()}`, {
        title: name,
        decorEnabled: true,
        isModal: false
      });

      await subWin.loadContent('pages/AppRunner');

      const w = 800;
      const h = 600;
      await subWin.resize(w, h);

      const prop = mainWindow.getWindowProperties();
      const displayInfo = display.getDisplayByIdSync(prop.displayId);
      const x = Math.round((displayInfo.availableWidth - w) / 2);
      const y = Math.round((displayInfo.availableHeight - h) / 2);
      await subWin.moveWindowToGlobal(x, y, { displayId: prop.displayId });

      await subWin.setWindowCornerRadius?.(8);
      await subWin.setWindowBackgroundColor('#FF1A1A1A');

      subWin.on('windowEvent', (event: window.WindowEventType) => {
        if (event === window.WindowEventType.WINDOW_DESTROYED) {
          runningWindows.remove(name);
        }
      });

      runningWindows.set(name, subWin);
      await subWin.showWindow();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`openAppWindow failed: ${err.code}, ${err.message}`);
    }
  }

  @Builder
  PageContent() {
    if (this.currentPage === PageType.LIBRARY) {
      LibraryPage({
        apps: $installedApps,
        onLaunch: this.launchApp,
        onDelete: this.deleteApp
      })
    } else if (this.currentPage === PageType.INSTALL) {
      InstallPage({ onInstalled: this.addApp })
    } else if (this.currentPage === PageType.SETTINGS) {
      SettingsPage()
    } else if (this.currentPage === PageType.FILES) {
      FilesPage()
    }
  }

  build() {
    Row() {
      Sidebar({ currentPage: $currentPage })

      Column() {
        this.PageContent()
      }
      .layoutWeight(1)
      .height('100%')
      .padding({ left: 28, right: 28, top: 28, bottom: 28 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Top)
    .backgroundColor(Theme.HM_BG)
  }
}