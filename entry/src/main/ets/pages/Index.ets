import { window, display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, PageType } from '../common/Theme';
import { AppInfo } from '../model/AppInfo';
import { runningWindows } from '../model/RunningWindow';
import { Sidebar } from '../components/Sidebar';
import { LibraryPage } from '../components/LibraryPage';
import { InstallPage } from '../components/InstallPage';
import { SettingsPage } from '../components/SettingsPage';
import { FilesPage } from '../components/FilesPage';

@Entry
@Component
struct Index {
  @State currentPage: string = PageType.LIBRARY;
  @State installedApps: AppInfo[] = [
    new AppInfo('微信 (Windows)', '💬'),
    new AppInfo('Steam', '🎮'),
    new AppInfo('Notepad++', '📝')
  ];

  launchApp = (name: string): void => {
    this.openAppWindow(name);
  }

  addApp = (name: string): void => {
    this.installedApps.push(new AppInfo(name, '📦'));
    this.currentPage = PageType.LIBRARY;
  }

  async openAppWindow(name: string): Promise<void> {
    try {
      // 已经打开过：置顶
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

      // 关键:在创建子窗口前把应用名写入 AppStorage
      // 子窗口的 AppRunner 在 aboutToAppear 中会读取一次
      AppStorage.setOrCreate<string>('currentAppName', name);

      const subWin = await mainWindow.createSubWindowWithOptions(`app_${name}`, {
        title: name,
        decorEnabled: true,
        isModal: false
      });

      // loadContent 加载页面(注意是 loadContent,不是 setUIContent)
      await subWin.loadContent('pages/AppRunner');

      // 大小与位置
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
      LibraryPage({ apps: $installedApps, onLaunch: this.launchApp })
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