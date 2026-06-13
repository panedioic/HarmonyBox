import { window, display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Theme, PageType } from '../common/Theme';
import { AppInfo, RuntimeMode, AppType } from '../model/AppInfo';
import { AppRegistry } from '../model/AppRegistry';
import { runningWindows } from '../model/RunningWindow';
import { InstallService } from '../service/InstallService';
import { WaylandService } from '../service/WaylandService';
import { Sidebar } from '../components/Sidebar';
import { LibraryPage } from '../components/LibraryPage';
import { InstallPage } from '../components/InstallPage';
import { SettingsPage } from '../components/SettingsPage';
import { FilesPage } from '../components/FilesPage';
import { CliService } from '../service/CliService';

@Entry
@Component
struct Index {
  @State currentPage: string = PageType.LIBRARY;
  @State installedApps: AppInfo[] = [];

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.installedApps = AppRegistry.load(ctx);
    WaylandService.getInstance().init(ctx);
    CliService.getInstance().init(ctx);
  }

  aboutToDisappear(): void {
    WaylandService.getInstance().shutdown();
  }

  launchApp = (app: AppInfo): void => {
    this.openAppWindow(app);
  }

  addApp = (app: AppInfo): void => {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.installedApps = AppRegistry.add(ctx, app);
    this.currentPage = PageType.LIBRARY;
  }

  deleteApp = (app: AppInfo): void => {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const running = runningWindows.get(app.id);
    if (running) {
      try { running.destroyWindow(); } catch (e) { /* ignore */ }
      runningWindows.remove(app.id);
      WaylandService.getInstance().stopCurrent();
    }
    try { InstallService.uninstall(ctx, app.installDir); } catch (e) { /* ignore */ }
    this.installedApps = AppRegistry.remove(ctx, app.id);
  }

  async openAppWindow(app: AppInfo): Promise<void> {
    // 仅支持 LINUX64
    if (app.type !== AppType.LINUX64) {
      this.toast(`暂不支持 $\{appTypeLabel(app.type)}`, 1500);
      return;
    }

    // 已经打开过 → 置顶
    const existing = runningWindows.get(app.id);
    if (existing) {
      await existing.showWindow();
      await existing.raiseToAppTop?.();
      return;
    }

    if (app.runtimeMode === RuntimeMode.CLI) {
      await this.openCliWindow(app);
    } else {
      await this.openGuiWindow(app);
    }
  }

  private toast(msg: string, dur: number = 1500): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: dur });
    } catch (e) { /* ignore */ }
  }

  private async openCliWindow(app: AppInfo): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const svc = CliService.getInstance();
    svc.init(ctx);
    const installRoot: string = `${ctx.filesDir}/${app.installDir}`;
    const exeAbs: string = `${installRoot}/${app.execPath}`;
    const userArgs: string[] = (app.config.args || '')
      .split(/\s+/)
      .filter((s: string): boolean => s.length > 0);
    const pid: number = svc.launchBox64(exeAbs, userArgs, installRoot);
    if (pid <= 0) {
      this.toast('启动 CLI 失败', 1500);
      return;
    }
    AppStorage.setOrCreate<string>('currentAppName', app.name);
    AppStorage.setOrCreate<number>('currentCliPid', pid);
    try {
      const windowStage = AppStorage.get<window.WindowStage>('windowStage');
      if (!windowStage) return;
      const main = windowStage.getMainWindowSync();
      const subWin = await main.createSubWindowWithOptions(
        `cli_${app.id}_${Date.now()}`,
        { title: `${app.name} (CLI)`, decorEnabled: true, isModal: false }
      );
      await subWin.loadContent('pages/CliRunner');
      const w: number = 1440;
      const h: number = 960;
      await subWin.resize(w, h);
      const prop = main.getWindowProperties();
      const di = display.getDisplayByIdSync(prop.displayId);
      await subWin.moveWindowToGlobal(
        Math.round((di.availableWidth - w) / 2),
        Math.round((di.availableHeight - h) / 2),
        { displayId: prop.displayId }
      );
      await subWin.setWindowCornerRadius?.(8);
      await subWin.setWindowBackgroundColor('#FF0E0E0E');
      subWin.on('windowEvent', (event: window.WindowEventType): void => {
        if (event === window.WindowEventType.WINDOW_DESTROYED) {
          runningWindows.remove(app.id);
          svc.stop(pid);
        }
      });
      runningWindows.set(app.id, subWin);
      await subWin.showWindow();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`openCliWindow failed: ${err.code}, ${err.message}`);
      svc.stop(pid);
    }
  }

  private async openGuiWindow(app: AppInfo): Promise<void> {
    const wlSvc = WaylandService.getInstance();
    if (!wlSvc.isServerReady()) {
      this.toast('Wayland 服务未就绪', 1500);
      return;
    }
    if (!wlSvc.isBox64Ready()) {
      this.toast('box64 未安装,请先部署 HNP 包', 1800);
      return;
    }
    if (wlSvc.getCurrentAppId()) {
      this.toast('已有 GUI 应用在运行,请先关闭', 1800);
      return;
    }

    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const exeAbs: string = `${ctx.filesDir}/${app.installDir}/${app.execPath}`;
    const userArgs: string[] = (app.config.args || '')
      .split(/\s+/)
      .filter((s: string): boolean => s.length > 0);

    this.toast(`正在启动 ${app.name}...`, 1200);

    const code: number = await wlSvc.launch(app.id, exeAbs, userArgs);
    if (code <= 0) {
      const reason = this.launchErrorText(code);
      this.toast(`${app.name} 启动失败: ${reason}`, 2500);
      return;
    }

    // active 已收到 → 创建子窗口承载 XComponent
    await this.createAppWindow(app);
  }

  private launchErrorText(code: number): string {
    if (code === -1) return 'Wayland 服务未就绪';
    if (code === -2) return '已有应用在运行';
    if (code === -3) return 'box64 未就绪';
    if (code === -4) return 'fork/exec 失败,详见 hilog';
    if (code === -5) return '客户端未在 15 秒内提交首帧';
    return `code=${code}`;
  }

  private async createAppWindow(app: AppInfo): Promise<void> {
    try {
      const windowStage = AppStorage.get<window.WindowStage>('windowStage');
      if (!windowStage) return;
      const main = windowStage.getMainWindowSync();

      AppStorage.setOrCreate<string>('currentAppName', app.name);

      const subWin = await main.createSubWindowWithOptions(
        `app_${app.id}_${Date.now()}`,
        { title: app.name, decorEnabled: true, isModal: false }
      );
      await subWin.loadContent('pages/AppRunner');

      const w: number = 800;
      const h: number = 600;
      await subWin.resize(w, h);

      const prop = main.getWindowProperties();
      const di = display.getDisplayByIdSync(prop.displayId);
      const x: number = Math.round((di.availableWidth - w) / 2);
      const y: number = Math.round((di.availableHeight - h) / 2);
      await subWin.moveWindowToGlobal(x, y, { displayId: prop.displayId });

      await subWin.setWindowCornerRadius?.(8);
      await subWin.setWindowBackgroundColor('#FF000000');

      subWin.on('windowEvent', (event: window.WindowEventType): void => {
        if (event === window.WindowEventType.WINDOW_DESTROYED) {
          runningWindows.remove(app.id);
          // 关窗 → 顺手停掉客户端
          WaylandService.getInstance().stopCurrent();
        }
      });

      runningWindows.set(app.id, subWin);
      await subWin.showWindow();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`createAppWindow failed: ${err.code}, ${err.message}`);
      WaylandService.getInstance().stopCurrent();
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