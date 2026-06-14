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
import { LibStore } from '../service/LibStore';

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

  private guiKey(appId: string): string { return `${appId}::gui`; }
  private cliKey(appId: string): string { return `${appId}::cli`; }

  private getAnyRunningWindow(appId: string): window.Window | undefined {
    return runningWindows.get(this.guiKey(appId)) ?? runningWindows.get(this.cliKey(appId));
  }

  launchApp = (app: AppInfo): void => {
    this.openAppWindow(app, false);
  }

  launchAppWithLog = (app: AppInfo): void => {
    this.openAppWindow(app, true);
  }

  addApp = (app: AppInfo): void => {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.installedApps = AppRegistry.add(ctx, app);
    this.currentPage = PageType.LIBRARY;
  }

  deleteApp = (app: AppInfo): void => {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    for (const k of [this.guiKey(app.id), this.cliKey(app.id)]) {
      const w = runningWindows.get(k);
      if (w) {
        try { w.destroyWindow(); } catch (e) { /* ignore */ }
        runningWindows.remove(k);
      }
    }
    WaylandService.getInstance().releaseSlot(app.id);
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

  private parseAppEnv(
    envText: string,
    ctx: common.UIAbilityContext,
    appDir: string
  ): string[] {
    if (!envText) return [];
    const x64Libs: string = LibStore.getDir(ctx);
    const filesDir: string = ctx.filesDir;
    const out: string[] = [];
    const parts: string[] = envText.split(/[;\n\r]+/);
    for (const raw of parts) {
      const line: string = raw.trim();
      if (!line || !line.includes('=')) continue;
      const expanded: string = line
        .replace(/\$\{APP_DIR\}/g, appDir)
        .replace(/\$\{X64_LIBS\}/g, x64Libs)
        .replace(/\$\{FILES_DIR\}/g, filesDir);
      out.push(expanded);
    }
    return out;
  }

  async openAppWindow(app: AppInfo, withLog: boolean): Promise<void> {
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
    }

    if (withLog) {
      await this.openGuiWithLog(app);
    } else {
      await this.openGuiWindow(app);
    }
  }

  private toast(msg: string, dur: number = 1500): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: dur });
    } catch (e) { /* ignore */ }
  }

  private launchErrorText(code: number): string {
    if (code === -1) return 'Wayland 服务未就绪';
    if (code === -2) return '已有应用在运行';
    if (code === -3) return 'box64 未就绪';
    if (code === -4) return 'fork/exec 失败';
    if (code === -5) return '客户端未在 15 秒内提交首帧';
    return `code=${code}`;
  }

  private async openCliWindow(app: AppInfo): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const svc = CliService.getInstance();
    svc.init(ctx);

    const installRoot: string = `${ctx.filesDir}/${app.installDir}`;
    const exeAbs: string = `${installRoot}/${app.execPath}`;
    const userArgs: string[] = (app.config.args || '')
      .split(/\s+/).filter((s: string): boolean => s.length > 0)
    const userEnv: string[] = this.parseAppEnv(app.config.envVars, ctx, installRoot);

    const pid: number = svc.launchBox64(exeAbs, userArgs, installRoot, userEnv);
    if (pid <= 0) {
      this.toast('启动 CLI 失败', 1500);
      return;
    }
    await this.createCliWindow(app, pid, false);
  }

  private async openGuiWindow(app: AppInfo): Promise<void> {
    const wlSvc = WaylandService.getInstance();
    if (!wlSvc.isServerReady()) { this.toast('Wayland 服务未就绪', 1500); return; }
    if (!wlSvc.isBox64Ready()) { this.toast('box64 未就绪', 1800); return; }
    if (wlSvc.getCurrentAppId()) { this.toast('已有 GUI 应用在运行', 1800); return; }

    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const installRoot: string = `${ctx.filesDir}/${app.installDir}`;
    const exeAbs: string = `${ctx.filesDir}/${app.installDir}/${app.execPath}`;
    const userArgs: string[] = (app.config.args || '')
      .split(/\s+/).filter((s: string): boolean => s.length > 0);
    const userEnv: string[] = this.parseAppEnv(app.config.envVars, ctx, installRoot);

    this.toast(`正在启动 ${app.name}...`, 1200);
    const code: number = await wlSvc.launch(app.id, exeAbs, userArgs, userEnv);
    if (code <= 0) {
      this.toast(`${app.name} 启动失败: ${this.launchErrorText(code)}`, 2500);
      return;
    }
    await this.createAppWindow(app);
  }

  private async openGuiWithLog(app: AppInfo): Promise<void> {
    const wlSvc = WaylandService.getInstance();
    const cliSvc = CliService.getInstance();

    if (!wlSvc.isServerReady()) { this.toast('Wayland 服务未就绪', 1500); return; }
    if (!wlSvc.isBox64Ready()) { this.toast('box64 未就绪', 1800); return; }
    if (!wlSvc.claimSlot(app.id)) { this.toast('已有 GUI 应用在运行', 1800); return; }

    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    cliSvc.init(ctx);

    const installRoot: string = `${ctx.filesDir}/${app.installDir}`;
    const exeAbs: string = `${installRoot}/${app.execPath}`;
    const userArgs: string[] = (app.config.args || '')
      .split(/\s+/).filter((s: string): boolean => s.length > 0);
    const userEnv: string[] = this.parseAppEnv(app.config.envVars, ctx, installRoot);

    // wayland 环境变量 + 用户自定义环境变量
    const env: string[] = [];
    for (const e of wlSvc.getWaylandEnv()) env.push(e);
    for (const e of userEnv) env.push(e);

    const pid: number = cliSvc.launchBox64(exeAbs, userArgs, installRoot, env);
    if (pid <= 0) {
      wlSvc.releaseSlot(app.id);
      this.toast('启动失败', 1500);
      return;
    }

    await this.createCliWindow(app, pid, true);
    this.toast(`正在启动 ${app.name}...`, 1200);

    const ok: boolean = await wlSvc.waitActive(15000);
    if (!ok) {
      this.toast('客户端未在 15s 内连接 Wayland', 2500);
      return;
    }
    await this.createAppWindow(app, pid);
  }

  private async createCliWindow(
    app: AppInfo, pid: number, attachedToGui: boolean
  ): Promise<void> {
    AppStorage.setOrCreate<string>('currentAppName', app.name);
    AppStorage.setOrCreate<number>('currentCliPid', pid);
    try {
      const windowStage = AppStorage.get<window.WindowStage>('windowStage');
      if (!windowStage) return;
      const main = windowStage.getMainWindowSync();
      const subWin = await main.createSubWindowWithOptions(
        `cli_${app.id}_${Date.now()}`,
        {
          title: attachedToGui ? `${app.name} (日志)` : `${app.name} (CLI)`,
          decorEnabled: true, isModal: false
        }
      );
      await subWin.loadContent('pages/CliRunner');
      const w: number = 1440; const h: number = 960;
      await subWin.resize(w, h);
      const prop = main.getWindowProperties();
      const di = display.getDisplayByIdSync(prop.displayId);
      // GUI 联动模式:CLI 窗口左移一些避免完全遮挡 GUI
      const offset: number = attachedToGui ? 200 : 0;
      await subWin.moveWindowToGlobal(
        Math.round((di.availableWidth - w) / 2 - offset),
        Math.round((di.availableHeight - h) / 2 + offset / 2),
        { displayId: prop.displayId }
      );
      await subWin.setWindowCornerRadius?.(8);
      await subWin.setWindowBackgroundColor('#FF0E0E0E');
      const key: string = this.cliKey(app.id);
      subWin.on('windowEvent', (event: window.WindowEventType): void => {
        if (event === window.WindowEventType.WINDOW_DESTROYED) {
          runningWindows.remove(key);
          // CLI 窗口被关 → 杀掉进程,GUI 也会随之退出
          CliService.getInstance().stop(pid);
          if (attachedToGui) {
            WaylandService.getInstance().releaseSlot(app.id);
            // 顺手关掉 GUI 窗口(如果已开)
            const guiWin = runningWindows.get(this.guiKey(app.id));
            if (guiWin) {
              try { guiWin.destroyWindow(); } catch (e) { /* ignore */ }
              runningWindows.remove(this.guiKey(app.id));
            }
          }
        }
      });
      runningWindows.set(key, subWin);
      await subWin.showWindow();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`createCliWindow failed: ${err.code}, ${err.message}`);
      CliService.getInstance().stop(pid);
      if (attachedToGui) WaylandService.getInstance().releaseSlot(app.id);
    }
  }
  private async createAppWindow(app: AppInfo, cliPid?: number): Promise<void> {
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
      const w: number = 800; const h: number = 600;
      await subWin.resize(w, h);
      const prop = main.getWindowProperties();
      const di = display.getDisplayByIdSync(prop.displayId);
      await subWin.moveWindowToGlobal(
        Math.round((di.availableWidth - w) / 2),
        Math.round((di.availableHeight - h) / 2),
        { displayId: prop.displayId }
      );
      await subWin.setWindowCornerRadius?.(8);
      await subWin.setWindowBackgroundColor('#FF000000');
      const key: string = this.guiKey(app.id);
      subWin.on('windowEvent', (event: window.WindowEventType): void => {
        if (event === window.WindowEventType.WINDOW_DESTROYED) {
          runningWindows.remove(key);
          WaylandService.getInstance().releaseSlot(app.id);
          if (cliPid !== undefined && cliPid > 0) {
            CliService.getInstance().stop(cliPid);
            // 顺手关 CLI 窗口
            const cliWin = runningWindows.get(this.cliKey(app.id));
            if (cliWin) {
              try { cliWin.destroyWindow(); } catch (e) { /* ignore */ }
              runningWindows.remove(this.cliKey(app.id));
            }
          }
        }
      });
      runningWindows.set(key, subWin);
      await subWin.showWindow();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`createAppWindow failed: ${err.code}, ${err.message}`);
      WaylandService.getInstance().releaseSlot(app.id);
    }
  }

  @Builder
  PageContent() {
    if (this.currentPage === PageType.LIBRARY) {
      LibraryPage({
        apps: $installedApps,
        onLaunch: this.launchApp,
        onLaunchWithLog: this.launchAppWithLog,
        onDelete: this.deleteApp,
        onEdit: this.editApp,
        onExport: this.exportApp,
        onUpdate: this.updateApp
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