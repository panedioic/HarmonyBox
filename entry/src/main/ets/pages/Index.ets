import { window, display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Theme, PageType } from '../common/Theme';
import { AppInfo, RuntimeMode, AppType } from '../model/AppInfo';
import { AppRegistry } from '../model/AppRegistry';
import { runningWindows } from '../model/RunningWindow';
import { InstallService } from '../service/InstallService';
import { WaylandService, WlBufferSize  } from '../service/WaylandService';
import { Sidebar } from '../components/Sidebar';
import { LibraryPage } from '../components/LibraryPage';
import { InstallPage } from '../components/InstallPage';
import { SettingsPage } from '../components/SettingsPage';
import { FilesPage } from '../components/FilesPage';
import { CliService } from '../service/CliService';
import { LibStore } from '../service/LibStore';
import { FontStore } from '../service/FontStore';

interface MovableWindow {
  startMoving?: () => Promise<void>;
}

interface MaximizableWindow {
  maximize?: () => Promise<void>;
  restore?: () => Promise<void>;
}

interface ResizableWindow {
  startResizing?: (edges: number) => Promise<void>;
}

interface HostSize {
  w: number;
  h: number;
}

@Entry
@Component
struct Index {
  @State currentPage: string = PageType.LIBRARY;
  @State installedApps: AppInfo[] = [];

  private firstCommitDone: Set<string> = new Set();
  private maximizedApps: Set<string> = new Set();
  private savedHostSizes: Map<string, HostSize> = new Map();
  private maxOpUntil: number = 0;        // 这个时间戳之前忽略 windowSizeChange
  private resizeDebounceTimer: number = -1;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.installedApps = AppRegistry.load(ctx);
    WaylandService.getInstance().init(ctx);
    CliService.getInstance().init(ctx);
    WaylandService.getInstance().setSizeListener((w: number, h: number): void => {
      this.handleWaylandSizeChange(w, h);
    });
    WaylandService.getInstance().setMoveListener((): void => {
      this.handleWaylandMoveRequest();
    });
    WaylandService.getInstance().setExitListener((): void => {
      this.handleClientExited();
    });
    WaylandService.getInstance().setMaximizeListener((): void => {
      this.handleWaylandMaximize();
    });
    WaylandService.getInstance().setUnmaximizeListener((): void => {
      this.handleWaylandUnmaximize();
    });
    WaylandService.getInstance().setResizeListener((edges: number): void => {
      this.handleWaylandResize(edges);
    });
  }

  aboutToDisappear(): void {
    WaylandService.getInstance().shutdown();
  }

  private handleWaylandSizeChange(bufW: number, bufH: number): void {
    if (bufW <= 0 || bufH <= 0) return;
    const appId: string | null = WaylandService.getInstance().getCurrentAppId();
    if (!appId) return;
    const guiWin: window.Window | undefined = runningWindows.get(this.guiKey(appId));
    if (!guiWin) return;

    // 仅在首帧时让 host 跟随 buffer。之后 host 由用户/最大化控制,
    // buffer 由我们通过 configure 反向通知客户端跟随 host。
    if (this.firstCommitDone.has(appId)) {
      return;
    }
    this.firstCommitDone.add(appId);
    this.applyWindowSize(guiWin, bufW, bufH);
  }

  private handleWaylandMoveRequest(): void {
    const appId: string | null = WaylandService.getInstance().getCurrentAppId();
    if (!appId) return;
    const guiWin: window.Window | undefined = runningWindows.get(this.guiKey(appId));
    if (!guiWin) return;
    try {
      const movable: MovableWindow = guiWin as MovableWindow;
      if (movable.startMoving) {
        movable.startMoving().catch((e: BusinessError): void => {
          console.error(`startMoving failed: ${e.code} ${e.message}`);
        });
      } else {
        console.warn('window.startMoving not available on this device');
      }
    } catch (e) {
      console.error(`handleWaylandMoveRequest failed: ${JSON.stringify(e)}`);
    }
  }

  private handleClientExited(): void {
    const appId: string | null = WaylandService.getInstance().getCurrentAppId();
    if (!appId) return;
    const guiWin: window.Window | undefined = runningWindows.get(this.guiKey(appId));
    if (guiWin) {
      guiWin.destroyWindow().catch((e: BusinessError): void => {
        console.error(`destroy gui window failed: ${e.code} ${e.message}`);
      });
    }
    // CLI 联动窗口在 windowEvent WINDOW_DESTROYED 链路里会被一起清理
  }

  private handleWaylandMaximize(): void {
    const appId: string | null = WaylandService.getInstance().getCurrentAppId();
    if (!appId) return;
    this.maximizedApps.add(appId);
    const guiWin: window.Window | undefined = runningWindows.get(this.guiKey(appId));
    if (!guiWin) return;

    // 1. 保存当前 host 尺寸,供 unmaximize 时还原
    try {
      const prop = guiWin.getWindowProperties();
      const r = prop.windowRect;
      this.savedHostSizes.set(appId, { w: r.width, h: r.height } as HostSize);
      console.info(`[HBox] saved host size ${r.width}x${r.height}`);
    } catch (e) { /* ignore */ }

    // 2. 屏蔽接下来 800ms 内的 windowSizeChange,避免动画中间帧打断
    this.maxOpUntil = Date.now() + 800;

    // 3. 用 display 可用区域算目标 buf 尺寸,先告诉客户端
    try {
      const di = display.getDefaultDisplaySync();
      this.sendConfigureFromHostSize(di.availableWidth, di.availableHeight, true);
    } catch (e) { /* ignore */ }

    // 4. 让 host 真正最大化
    try {
      const maximizable: MaximizableWindow = guiWin as MaximizableWindow;
      if (maximizable.maximize) {
        maximizable.maximize().catch((e: BusinessError): void => {
          console.warn(`maximize failed: ${e.code} ${e.message}`);
        });
      }
    } catch (e) { /* ignore */ }
  }

  private handleWaylandUnmaximize(): void {
    const appId: string | null = WaylandService.getInstance().getCurrentAppId();
    if (!appId) return;
    this.maximizedApps.delete(appId);
    const guiWin: window.Window | undefined = runningWindows.get(this.guiKey(appId));
    if (!guiWin) return;

    this.maxOpUntil = Date.now() + 800;

    // 用保存的 host 尺寸通知客户端
    const saved: HostSize | undefined = this.savedHostSizes.get(appId);
    if (saved) {
      this.sendConfigureFromHostSize(saved.w, saved.h, false);
    }
    this.savedHostSizes.delete(appId);

    try {
      const maximizable: MaximizableWindow = guiWin as MaximizableWindow;
      if (maximizable.restore) {
        maximizable.restore().catch((e: BusinessError): void => {
          console.warn(`restore failed: ${e.code} ${e.message}`);
        });
      }
    } catch (e) { /* ignore */ }
  }

  private handleHostResize(appId: string, hostW: number, hostH: number): void {
    if (!this.firstCommitDone.has(appId)) return;
    if (hostW <= 0 || hostH <= 0) return;
    if (Date.now() < this.maxOpUntil) return; // max/unmax 期间静默

    if (this.resizeDebounceTimer >= 0) {
      clearTimeout(this.resizeDebounceTimer);
    }
    this.resizeDebounceTimer = setTimeout((): void => {
      this.resizeDebounceTimer = -1;
      const maximized: boolean = this.maximizedApps.has(appId);
      this.sendConfigureFromHostSize(hostW, hostH, maximized);
    }, 150);
  }

  private handleWaylandResize(edges: number): void {
    const appId: string | null = WaylandService.getInstance().getCurrentAppId();
    if (!appId) return;
    const guiWin: window.Window | undefined = runningWindows.get(this.guiKey(appId));
    if (!guiWin) return;
    try {
      const resizable: ResizableWindow = guiWin as ResizableWindow;
      if (resizable.startResizing && typeof resizable.startResizing === 'function') {
        resizable.startResizing(edges)
          .then((): void => {
            console.info(`[WL] startResizing succeeded edges=0x${edges.toString(16)}`);
          })
          .catch((e: BusinessError): void => {
            console.warn(`startResizing not supported or failed: ${e.code} ${e.message}`);
          });
      } else {
        console.warn('window.startResizing not available on this device');
      }
    } catch (e) {
      console.warn(`handleWaylandResize error: ${JSON.stringify(e)}`);
    }
  }

  private sendConfigureFromHostSize(hostW: number, hostH: number, maximized: boolean): void {
    const scale: number = WaylandService.getInstance().getUiScale();
    const useDecor: boolean = WaylandService.getInstance().getUseNativeDecor();
    let decorPx: number = 0;
    if (useDecor) {
      try {
        const di = display.getDefaultDisplaySync();
        const density: number = di.densityPixels ?? 1;
        decorPx = Math.round(45 * density);
      } catch (e) { /* ignore */ }
    }
    const bufW: number = Math.max(1, Math.round(hostW / scale));
    const bufH: number = Math.max(1, Math.round((hostH - decorPx) / scale));
    console.info(`[HBox] configure -> client: host=${hostW}x${hostH} buf=${bufW}x${bufH} max=${maximized}`);
    WaylandService.getInstance().requestClientResize(bufW, bufH, maximized);
  }

  private applyWindowSize(win: window.Window, bufW: number, bufH: number): void {
    const wlSvc = WaylandService.getInstance();
    const scale: number = wlSvc.getUiScale();
    const useNative: boolean = wlSvc.getUseNativeDecor();

    let decorPx: number = 0;
    if (useNative) {
      try {
        const di = display.getDefaultDisplaySync();
        const density: number = di.densityPixels ?? 1;
        decorPx = Math.round(45 * density);
      } catch (e) {
        decorPx = 90;
      }
    }

    const totalW: number = Math.max(1, Math.round(bufW * scale));
    const totalH: number = Math.max(1, Math.round(bufH * scale)) + decorPx;
    console.info(`[HBox] resize host: buf=${bufW}x${bufH} scale=${scale} ` +
      `decor=${decorPx} total=${totalW}x${totalH}`);

    win.resize(totalW, totalH).then((): void => {
      try {
        const prop = win.getWindowProperties();
        const di = display.getDisplayByIdSync(prop.displayId);
        win.moveWindowToGlobal(
          Math.round((di.availableWidth - totalW) / 2),
          Math.round((di.availableHeight - totalH) / 2),
          { displayId: prop.displayId }
        ).catch((): void => { /* ignore */ });
      } catch (e) { /* ignore */ }
    }).catch((e: BusinessError): void => {
      console.error(`resize gui window failed: ${e.code} ${e.message}`);
    });
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
        w.destroyWindow().catch(() => {
          // TODO: Implement error handling.
        });
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
      try {
        await existing.showWindow();
        await existing.raiseToAppTop?.();
      } catch (error) {
        // TODO: Implement error handling.
      }
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
    for (const e of FontStore.buildEnv(ctx)) env.push(e);
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
              guiWin.destroyWindow().catch(() => {
                // TODO: Implement error handling.
              });
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

      const useNative: boolean = WaylandService.getInstance().getUseNativeDecor();
      const subWin = await main.createSubWindowWithOptions(
        `app_${app.id}_${Date.now()}`,
        { title: app.name, decorEnabled: useNative, isModal: false, maximizeSupported: true }
      );
      await subWin.loadContent('pages/AppRunner');
      const w: number = 800; const h: number = 600;
      const fallbackScale: number = WaylandService.getInstance().getUiScale();
      await subWin.resize(Math.round(w * fallbackScale), Math.round(h * fallbackScale));
      const prop = main.getWindowProperties();
      const di = display.getDisplayByIdSync(prop.displayId);
      await subWin.moveWindowToGlobal(
        Math.round((di.availableWidth - w * fallbackScale) / 2),
        Math.round((di.availableHeight - h * fallbackScale) / 2),
        { displayId: prop.displayId }
      );
      await subWin.setWindowCornerRadius?.(useNative ? 8 : 4);
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
              cliWin.destroyWindow().catch(() => {
                // TODO: Implement error handling.
              });
              runningWindows.remove(this.cliKey(app.id));
            }
          }
        }
      });
      runningWindows.set(key, subWin);
      subWin.on('windowSizeChange', (size: window.Size): void => {
        this.handleHostResize(app.id, size.width, size.height);
      });
      await subWin.showWindow();
      // 首帧可能早于子窗口创建,这里主动同步一次最新 buffer 尺寸
      const sz: WlBufferSize  = WaylandService.getInstance().getLatestBufferSize();
      if (sz.w > 0 && sz.h > 0) {
        this.applyWindowSize(subWin, sz.w, sz.h);
      }
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