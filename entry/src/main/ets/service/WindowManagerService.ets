import { window, display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { AppInfo, RuntimeMode, AppType, appTypeLabel } from '../model/AppInfo';
import { runningWindows } from '../model/RunningWindow';
import { WaylandService, WlBufferSize } from './WaylandService';
import { CliService, LaunchResult } from './CliService';
import { LibStore } from './LibStore';

interface MovableWindow { startMoving?: () => Promise<void>; }
interface RestorableWindow {
  showWindow?: () => Promise<void>;
  raiseToAppTop?: () => Promise<void>;
}
interface HostSize { w: number; h: number; x: number; y: number; }
interface ResizeStart {
  edges: number;
  startX: number; startY: number;
  startW: number; startH: number;
}

export type RunningIdsListener = (ids: string[]) => void;
export type ToastFn = (msg: string, dur: number) => void;

export class WindowManagerService {
  private static instance: WindowManagerService | null = null;
  static getInstance(): WindowManagerService {
    if (!WindowManagerService.instance) {
      WindowManagerService.instance = new WindowManagerService();
    }
    return WindowManagerService.instance;
  }

  private ctx: common.UIAbilityContext | null = null;
  private installed: boolean = false;
  private toastFn: ToastFn | null = null;

  private runningAppIds: string[] = [];
  private runningIdsListener: RunningIdsListener | null = null;

  private firstCommitDone: Set<string> = new Set();
  private maximizedApps: Set<string> = new Set();
  private savedHostSizes: Map<string, HostSize> = new Map();
  private maxOpUntil: number = 0;
  private resizeDebounceTimer: number = -1;
  private resizeStart: ResizeStart | null = null;
  private resizeDragLastConfigure: number = 0;

  // auto host window (shell 起的 wine 客户端用)
  private autoWindowSeq: number = 0;
  private autoWindowAppIds: Set<string> = new Set();

  // =========================================================
  // lifecycle
  // =========================================================
  init(ctx: common.UIAbilityContext): void {
    this.ctx = ctx;
    if (this.installed) return;

    CliService.getInstance().init(ctx);

    const wlSvc = WaylandService.getInstance();
    wlSvc.init(ctx);

    wlSvc.setSizeListener((w: number, h: number): void => {
      this.handleWaylandSizeChange(w, h);
    });
    wlSvc.setMoveListener((): void => { this.handleWaylandMoveRequest(); });
    wlSvc.setExitListener((): void => { this.handleClientExited(); });
    wlSvc.setMaximizeListener((): void => { this.handleWaylandMaximize(); });
    wlSvc.setUnmaximizeListener((): void => { this.handleWaylandUnmaximize(); });
    wlSvc.setResizeListener((edges: number): void => {
      this.handleWaylandResize(edges);
    });
    wlSvc.setHostResizeDragListener(
      (edges: number, dxPx: number, dyPx: number): void => {
        this.handleHostResizeDrag(edges, dxPx, dyPx);
      });
    wlSvc.setHostResizeEndListener((): void => { this.handleHostResizeEnd(); });
    wlSvc.setMinimizeListener((): void => { this.handleWaylandMinimize(); });

    // state=active 但没人等 waitActive 时的兜底: 自动开窗 (shell 场景)
    wlSvc.setAutoActiveListener((): void => {
      this.autoCreateHostWindow().catch((e: BusinessError): void => {
        console.error(`HBOX_AUTO_WIN_ERR code=${e.code} msg=${e.message}`);
      });
    });

    this.installed = true;
  }

  shutdown(): void {
    WaylandService.getInstance().shutdown();
  }

  setToastFn(fn: ToastFn | null): void { this.toastFn = fn; }

  private toast(msg: string, dur: number = 1500): void {
    if (this.toastFn) this.toastFn(msg, dur);
  }

  // =========================================================
  // running ids
  // =========================================================
  setRunningIdsListener(cb: RunningIdsListener | null): void {
    this.runningIdsListener = cb;
    if (cb) cb(this.runningAppIds.slice());
  }

  private guiKey(appId: string): string { return `${appId}::gui`; }
  private cliKey(appId: string): string { return `${appId}::cli`; }

  private getAnyRunningWindow(appId: string): window.Window | undefined {
    return runningWindows.get(this.guiKey(appId))
      ?? runningWindows.get(this.cliKey(appId));
  }

  private addRunningId(id: string): void {
    if (!this.runningAppIds.includes(id)) {
      this.runningAppIds = [...this.runningAppIds, id];
      if (this.runningIdsListener) this.runningIdsListener(this.runningAppIds.slice());
    }
  }

  private removeRunningIdIfGone(id: string): void {
    const hasGui: boolean = runningWindows.get(this.guiKey(id)) !== undefined;
    const hasCli: boolean = runningWindows.get(this.cliKey(id)) !== undefined;
    if (!hasGui && !hasCli) {
      this.runningAppIds = this.runningAppIds.filter((x: string): boolean => x !== id);
      if (this.runningIdsListener) this.runningIdsListener(this.runningAppIds.slice());
    }
  }

  // =========================================================
  // public: launch / close
  // =========================================================
  async launchApp(app: AppInfo, withLog: boolean): Promise<void> {
    const existing: window.Window | undefined = this.getAnyRunningWindow(app.id);
    if (existing) {
      this.restoreHiddenWindow(existing, app.id);
      return;
    }
    await this.openAppWindow(app, withLog);
  }

  closeApp(appId: string): void {
    for (const k of [this.guiKey(appId), this.cliKey(appId)]) {
      const w = runningWindows.get(k);
      if (w) {
        w.destroyWindow().catch((): void => { /* ignore */ });
        runningWindows.remove(k);
      }
    }
    WaylandService.getInstance().releaseSlot(appId);
    this.removeRunningIdIfGone(appId);
  }

  private restoreHiddenWindow(win: window.Window, appId: string): void {
    const r: RestorableWindow = win as RestorableWindow;
    if (r.showWindow) {
      r.showWindow().then((): void => {
        if (r.raiseToAppTop) r.raiseToAppTop().catch((): void => {});
      }).catch((e: BusinessError): void => {
        console.warn(`HBOX_GUI_RESTORE_FAIL code=${e.code} msg=${e.message}`);
      });
    }
  }

  // =========================================================
  // wayland event handlers (原 Index 中的 handleXxx, 内容不变)
  // =========================================================
  private handleWaylandSizeChange(bufW: number, bufH: number): void {
    if (bufW <= 0 || bufH <= 0) return;
    const appId: string | null = WaylandService.getInstance().getCurrentAppId();
    if (!appId) return;
    const guiWin: window.Window | undefined = runningWindows.get(this.guiKey(appId));
    if (!guiWin) return;
    if (this.firstCommitDone.has(appId)) return;
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
  }

  private handleWaylandMaximize(): void {
    const appId: string | null = WaylandService.getInstance().getCurrentAppId();
    if (!appId) return;
    if (this.maximizedApps.has(appId)) return;
    this.maximizedApps.add(appId);
    const guiWin: window.Window | undefined = runningWindows.get(this.guiKey(appId));
    if (!guiWin) return;
    try {
      const prop = guiWin.getWindowProperties();
      const r = prop.windowRect;
      this.savedHostSizes.set(appId, { w: r.width, h: r.height, x: r.left, y: r.top });
    } catch (e) { /* ignore */ }
    this.maxOpUntil = Date.now() + 1000;
    let availW: number = 0;
    let availH: number = 0;
    try {
      const di = display.getDefaultDisplaySync();
      availW = di.availableWidth;
      availH = di.availableHeight;
    } catch (e) { /* ignore */ }
    if (availW <= 0 || availH <= 0) return;
    this.sendConfigureFromHostSize(availW, availH, true);
    guiWin.resize(availW, availH).then((): void => {
      guiWin.moveWindowToGlobal(0, 0).catch((): void => {});
    }).catch((e: BusinessError): void => {
      console.warn(`HBOX_WIN_RESIZE_MAX_FAIL code=${e.code}`);
    });
  }

  private handleWaylandUnmaximize(): void {
    const appId: string | null = WaylandService.getInstance().getCurrentAppId();
    if (!appId) return;
    if (!this.maximizedApps.has(appId)) return;
    this.maximizedApps.delete(appId);
    const guiWin: window.Window | undefined = runningWindows.get(this.guiKey(appId));
    if (!guiWin) return;
    this.maxOpUntil = Date.now() + 1000;
    const saved: HostSize | undefined = this.savedHostSizes.get(appId);
    this.savedHostSizes.delete(appId);
    if (!saved) return;
    this.sendConfigureFromHostSize(saved.w, saved.h, false);
    guiWin.resize(saved.w, saved.h).then((): void => {
      guiWin.moveWindowToGlobal(saved.x, saved.y).catch((): void => {});
    }).catch((e: BusinessError): void => {
      console.warn(`HBOX_WIN_RESIZE_UNMAX_FAIL code=${e.code}`);
    });
  }

  private handleHostResize(appId: string, hostW: number, hostH: number): void {
    if (!this.firstCommitDone.has(appId)) return;
    if (hostW <= 0 || hostH <= 0) return;
    if (Date.now() < this.maxOpUntil) return;
    if (this.resizeDebounceTimer >= 0) clearTimeout(this.resizeDebounceTimer);
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
      const r = guiWin.getWindowProperties().windowRect;
      this.resizeStart = {
        edges,
        startX: r.left, startY: r.top,
        startW: r.width, startH: r.height
      };
      WaylandService.getInstance().fireHostResizeBegin(edges);
    } catch (e) {
      console.warn(`HBOX_GUI_RESIZE_DRAG_INDEX_FAIL ${JSON.stringify(e)}`);
    }
  }

  private handleHostResizeDrag(edges: number, dxPx: number, dyPx: number): void {
    if (!this.resizeStart) return;
    const s: ResizeStart = this.resizeStart;
    const appId: string | null = WaylandService.getInstance().getCurrentAppId();
    if (!appId) return;
    const guiWin: window.Window | undefined = runningWindows.get(this.guiKey(appId));
    if (!guiWin) return;
    let newX: number = s.startX;
    let newY: number = s.startY;
    let newW: number = s.startW;
    let newH: number = s.startH;
    if ((edges & 1) !== 0) { newY = s.startY + dyPx; newH = s.startH - dyPx; }
    if ((edges & 2) !== 0) { newH = s.startH + dyPx; }
    if ((edges & 4) !== 0) { newX = s.startX + dxPx; newW = s.startW - dxPx; }
    if ((edges & 8) !== 0) { newW = s.startW + dxPx; }
    const minW: number = 200;
    const minH: number = 120;
    if (newW < minW) {
      if ((edges & 4) !== 0) newX = s.startX + s.startW - minW;
      newW = minW;
    }
    if (newH < minH) {
      if ((edges & 1) !== 0) newY = s.startY + s.startH - minH;
      newH = minH;
    }
    guiWin.resize(newW, newH).then((): void => {
      guiWin.moveWindowToGlobal(newX, newY).catch((): void => {});
    }).catch((e: BusinessError): void => {
      console.warn(`HBOX_GUI_RESIZE_DRAG_HOST_FAIL code=${e.code}`);
    });
    const now: number = Date.now();
    if (now - this.resizeDragLastConfigure >= 80) {
      this.resizeDragLastConfigure = now;
      this.sendConfigureFromHostSize(newW, newH, false);
    }
  }

  private handleHostResizeEnd(): void {
    const appId: string | null = WaylandService.getInstance().getCurrentAppId();
    if (appId) {
      const guiWin: window.Window | undefined = runningWindows.get(this.guiKey(appId));
      if (guiWin) {
        try {
          const r = guiWin.getWindowProperties().windowRect;
          this.sendConfigureFromHostSize(r.width, r.height, false);
        } catch (e) { /* ignore */ }
      }
    }
    this.resizeStart = null;
    this.resizeDragLastConfigure = 0;
    this.maxOpUntil = Date.now() + 300;
  }

  private handleWaylandMinimize(): void {
    const appId: string | null = WaylandService.getInstance().getCurrentAppId();
    if (!appId) return;
    const guiWin: window.Window | undefined = runningWindows.get(this.guiKey(appId));
    if (!guiWin) return;
    guiWin.minimize().catch((e: BusinessError): void => {
      console.warn(`HBOX_GUI_MIN_FAIL code=${e.code} msg=${e.message}`);
    });
  }

  private sendConfigureFromHostSize(hostW: number, hostH: number, maximized: boolean): void {
    const wlSvc = WaylandService.getInstance();
    const scale: number = wlSvc.getUiScale();
    const useDecor: boolean = wlSvc.getUseNativeDecor();
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
    wlSvc.requestClientResize(bufW, bufH, maximized);
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
    win.resize(totalW, totalH).then((): void => {
      try {
        const prop = win.getWindowProperties();
        const di = display.getDisplayByIdSync(prop.displayId);
        win.moveWindowToGlobal(
          Math.round((di.availableWidth - totalW) / 2),
          Math.round((di.availableHeight - totalH) / 2),
          { displayId: prop.displayId }
        ).catch((): void => {});
      } catch (e) { /* ignore */ }
    }).catch((e: BusinessError): void => {
      console.error(`resize gui window failed: ${e.code} ${e.message}`);
    });
  }

  // =========================================================
  // openAppWindow (原 Index)
  // =========================================================
  private parseAppEnv(envText: string, ctx: common.UIAbilityContext, appDir: string): string[] {
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

  private async openAppWindow(app: AppInfo, withLog: boolean): Promise<void> {
    if (app.type !== AppType.LINUX && app.type !== AppType.WINDOWS) {
      this.toast(`暂不支持 ${appTypeLabel(app.type)}`, 1500);
      return;
    }
    const ctx = this.ctx;
    if (!ctx) return;
    const cliSvc = CliService.getInstance();

    const isCliMode: boolean = app.runtimeMode === RuntimeMode.CLI;
    const isGui: boolean = !isCliMode;
    const showLog: boolean = isCliMode || withLog;

    const installRoot: string = `${ctx.filesDir}/${app.installDir}`;
    const exeAbs: string = `${installRoot}/${app.execPath}`;
    const userArgs: string[] = (app.config.args || '')
      .split(/\s+/).filter((s: string): boolean => s.length > 0);
    const userEnv: string[] = this.parseAppEnv(app.config.envVars, ctx, installRoot);

    this.toast(`正在启动 ${app.name}...`, 1200);

    const result: LaunchResult = cliSvc.launchBox64({
      appId: app.id,
      exeAbsPath: exeAbs,
      extraArgs: userArgs,
      cwd: installRoot,
      extraEnv: userEnv,
      appDir: installRoot,
      useWine: app.type === AppType.WINDOWS,
      gui: isGui,
      streaming: showLog
    });

    if (result.code !== 0) {
      this.toast(`${app.name} 启动失败: ${result.errorMsg}`, 2500);
      return;
    }

    if (showLog) {
      await this.createCliWindow(app, result.pid, isGui);
    }

    if (isGui) {
      const ok: boolean = await WaylandService.getInstance().waitActive();
      if (!ok) {
        cliSvc.stop(result.pid);
        WaylandService.getInstance().releaseSlot(app.id);
        this.toast('客户端未在 15s 内连接 Wayland', 2500);
        return;
      }
      await this.createAppWindow(app, result.pid);
    }
  }

  private async createCliWindow(app: AppInfo, pid: number, attachedToGui: boolean): Promise<void> {
    AppStorage.setOrCreate<string>('currentAppName', app.name);
    AppStorage.setOrCreate<number>('currentCliPid', pid);
    try {
      const windowStage = AppStorage.get<window.WindowStage>('windowStage');
      if (!windowStage) return;
      const main = windowStage.getMainWindowSync();
      const subWin = await main.createSubWindowWithOptions(
        `cli_${app.id}_${Date.now()}`,
        { title: attachedToGui ? `${app.name} (日志)` : `${app.name} (CLI)`,
          decorEnabled: true, isModal: false }
      );
      await subWin.loadContent('pages/CliRunner');
      const w: number = 1440;
      const h: number = 960;
      await subWin.resize(w, h);
      const prop = main.getWindowProperties();
      const di = display.getDisplayByIdSync(prop.displayId);
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
          CliService.getInstance().stop(pid);
          if (attachedToGui) {
            WaylandService.getInstance().releaseSlot(app.id);
            const guiWin = runningWindows.get(this.guiKey(app.id));
            if (guiWin) {
              guiWin.destroyWindow().catch((): void => {});
              runningWindows.remove(this.guiKey(app.id));
            }
          }
          this.removeRunningIdIfGone(app.id);
        }
      });
      runningWindows.set(key, subWin);
      this.addRunningId(app.id);
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

      const fallbackScale: number = WaylandService.getInstance().getUiScale();
      const w: number = 800;
      const h: number = 600;
      await subWin.resize(Math.round(w * fallbackScale), Math.round(h * fallbackScale));
      const prop = main.getWindowProperties();
      const di = display.getDisplayByIdSync(prop.displayId);
      await subWin.moveWindowToGlobal(
        Math.round((di.availableWidth - w * fallbackScale) / 2),
        Math.round((di.availableHeight - h * fallbackScale) / 2),
        { displayId: prop.displayId }
      );
      await subWin.setWindowCornerRadius?.(useNative ? 8 : 0);
      await subWin.setWindowBackgroundColor('#FF000000');

      const key: string = this.guiKey(app.id);
      subWin.on('windowEvent', (event: window.WindowEventType): void => {
        if (event === window.WindowEventType.WINDOW_DESTROYED) {
          runningWindows.remove(key);
          WaylandService.getInstance().releaseSlot(app.id);
          if (cliPid !== undefined && cliPid > 0) {
            CliService.getInstance().stop(cliPid);
            const cliWin = runningWindows.get(this.cliKey(app.id));
            if (cliWin) {
              cliWin.destroyWindow().catch((): void => {});
              runningWindows.remove(this.cliKey(app.id));
            }
          }
          this.firstCommitDone.delete(app.id);
          this.maximizedApps.delete(app.id);
          this.savedHostSizes.delete(app.id);
          this.removeRunningIdIfGone(app.id);
        }
      });
      runningWindows.set(key, subWin);
      this.addRunningId(app.id);
      subWin.on('windowSizeChange', (size: window.Size): void => {
        this.handleHostResize(app.id, size.width, size.height);
      });

      await subWin.showWindow();

      const sz: WlBufferSize = WaylandService.getInstance().getLatestBufferSize();
      if (sz.w > 0 && sz.h > 0) {
        this.applyWindowSize(subWin, sz.w, sz.h);
      }
    } catch (e) {
      const err = e as BusinessError;
      console.error(`createAppWindow failed: ${err.code}, ${err.message}`);
      WaylandService.getInstance().releaseSlot(app.id);
    }
  }

  // =========================================================
  // auto host window (shell 里 wine notepad 之类)
  // =========================================================
  private async autoCreateHostWindow(): Promise<void> {
    const ctx = this.ctx;
    if (!ctx) return;

    const wlSvc = WaylandService.getInstance();
    const appId: string = `auto-${++this.autoWindowSeq}`;
    if (!wlSvc.claimSlot(appId)) {
      console.warn('HBOX_AUTO_WIN_SKIP slot taken');
      return;
    }

    const stashed: string | undefined = AppStorage.get<string>('currentAppName');
    const title: string = (stashed && stashed.length > 0) ? stashed : 'External App';

    try {
      const windowStage = AppStorage.get<window.WindowStage>('windowStage');
      if (!windowStage) {
        console.error('HBOX_AUTO_WIN_NO_STAGE');
        wlSvc.releaseSlot(appId);
        return;
      }
      const main = windowStage.getMainWindowSync();
      AppStorage.setOrCreate<string>('currentAppName', title);

      const useNative: boolean = wlSvc.getUseNativeDecor();
      const subWin: window.Window = await main.createSubWindowWithOptions(
        `auto_${appId}_${Date.now()}`,
        { title, decorEnabled: useNative, isModal: false, maximizeSupported: true }
      );
      await subWin.loadContent('pages/AppRunner');

      const sz: WlBufferSize = wlSvc.getLatestBufferSize();
      const bufW: number = sz.w > 0 ? sz.w : 800;
      const bufH: number = sz.h > 0 ? sz.h : 600;
      const scale: number = wlSvc.getUiScale();
      const totalW: number = Math.max(1, Math.round(bufW * scale));
      const totalH: number = Math.max(1, Math.round(bufH * scale));

      await subWin.resize(totalW, totalH);
      const prop = main.getWindowProperties();
      const di = display.getDisplayByIdSync(prop.displayId);
      await subWin.moveWindowToGlobal(
        Math.round((di.availableWidth - totalW) / 2),
        Math.round((di.availableHeight - totalH) / 2),
        { displayId: prop.displayId }
      );
      await subWin.setWindowCornerRadius?.(useNative ? 8 : 0);
      await subWin.setWindowBackgroundColor('#FF000000');

      const key: string = this.guiKey(appId);
      subWin.on('windowEvent', (event: window.WindowEventType): void => {
        if (event === window.WindowEventType.WINDOW_DESTROYED) {
          runningWindows.remove(key);
          wlSvc.releaseSlot(appId);
          this.autoWindowAppIds.delete(appId);
          this.firstCommitDone.delete(appId);
          this.maximizedApps.delete(appId);
          this.savedHostSizes.delete(appId);
          this.removeRunningIdIfGone(appId);
        }
      });
      subWin.on('windowSizeChange', (size: window.Size): void => {
        this.handleHostResize(appId, size.width, size.height);
      });
      runningWindows.set(key, subWin);
      this.autoWindowAppIds.add(appId);
      this.addRunningId(appId);
      await subWin.showWindow();
      console.info(`HBOX_AUTO_WIN_SHOWN app=${appId} ${totalW}x${totalH}`);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`HBOX_AUTO_WIN_FAIL code=${err.code} msg=${err.message}`);
      wlSvc.releaseSlot(appId);
    }
  }
}