import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Theme, PageType } from '../common/Theme';
import { AppInfo } from '../model/AppInfo';
import { AppRegistry } from '../model/AppRegistry';
import { InstallService } from '../service/InstallService';
import { WaylandService } from '../service/WaylandService';
import { WindowManagerService } from '../service/WindowManagerService';
import { Sidebar } from '../components/Sidebar';
import { LibraryPage } from '../components/LibraryPage';
import { InstallPage } from '../components/InstallPage';
import { SettingsPage } from '../components/SettingsPage';
import { FilesPage } from '../components/FilesPage';
import { ProcManagerPage } from '../components/ProcManagerPage';
import { DebugPage } from '../pages/DebugPage';
import { DebugShellPage } from './DebugShellPage';
import { ContainerManagerPage } from '../pages/ContainerManagerPage';

@Entry
@Component
struct Index {
  @State currentPage: string = PageType.LIBRARY;
  @State installedApps: AppInfo[] = [];
  @State runningAppIds: string[] = [];
  windowClass: window.Window | undefined = AppStorage.get('windowClass');
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.installedApps = AppRegistry.load(ctx);

    const wm = WindowManagerService.getInstance();
    wm.init(ctx);
    wm.setToastFn((msg: string, dur: number): void => this.toast(msg, dur));
    wm.setRunningIdsListener((ids: string[]): void => {
      this.runningAppIds = ids;
    });
  }

  aboutToDisappear(): void {
    WindowManagerService.getInstance().setRunningIdsListener(null);
    WindowManagerService.getInstance().setToastFn(null);
    WindowManagerService.getInstance().shutdown();
  }

  // =========================================================
  // app actions
  // =========================================================
  launchApp = (app: AppInfo): void => {
    WindowManagerService.getInstance().launchApp(app, false).catch((e: BusinessError): void => {
      console.error(`launchApp failed: ${e.code} ${e.message}`);
    });
  }

  launchAppWithLog = (app: AppInfo): void => {
    WindowManagerService.getInstance().launchApp(app, true).catch((e: BusinessError): void => {
      console.error(`launchAppWithLog failed: ${e.code} ${e.message}`);
    });
  }

  addApp = (app: AppInfo): void => {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.installedApps = AppRegistry.add(ctx, app);
    this.currentPage = PageType.LIBRARY;
  }

  deleteApp = (app: AppInfo): void => {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    WindowManagerService.getInstance().closeApp(app.id);
    try { InstallService.uninstall(ctx, app.installDir); } catch (e) { /* ignore */ }
    this.installedApps = AppRegistry.remove(ctx, app.id);
  }

  editApp = (updated: AppInfo): void => {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.installedApps = AppRegistry.update(ctx, updated);
    this.toast(`已保存「${updated.name}」`, 1200);
  }

  exportApp = (app: AppInfo): void => {
    this.toast('导出应用功能尚未实现', 1500);
  }

  updateApp = (app: AppInfo): void => {
    this.toast('更新应用功能尚未实现', 1500);
  }

  private toast(msg: string, dur: number = 1500): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: dur });
    } catch (e) { /* ignore */ }
  }

  // =========================================================
  // UI
  // =========================================================
  @Builder
  PageContent() {
    if (this.currentPage === PageType.LIBRARY) {
      LibraryPage({
        apps: $installedApps,
        runningIds: this.runningAppIds,
        onLaunch: this.launchApp,
        onLaunchWithLog: this.launchAppWithLog,
        onDelete: this.deleteApp,
        onEdit: this.editApp,
        onExport: this.exportApp,
        onUpdate: this.updateApp,
        onInstalled: this.addApp
      })
    } else if (this.currentPage === PageType.INSTALL) {
      InstallPage({ onInstalled: this.addApp })
    } else if (this.currentPage === PageType.SETTINGS) {
      SettingsPage()
    } else if (this.currentPage === PageType.FILES) {
      FilesPage()
    } else if (this.currentPage === PageType.PROC_MANAGER) {
      ProcManagerPage()
    } else if (this.currentPage === PageType.DEBUG_SHELL) {
      DebugShellPage()
    } else if (this.currentPage === PageType.DEBUG) {
      DebugPage()
    } else if (this.currentPage === PageType.CONTAINER) {
      ContainerManagerPage()
    }
  }

  @Builder
  CustomDecor() {
    Column() {
      Row() { }
      .height(24)
    }
  }

  build() {
    Row() {
      Sidebar({ currentPage: $currentPage })
      Column() {
        this.CustomDecor()
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