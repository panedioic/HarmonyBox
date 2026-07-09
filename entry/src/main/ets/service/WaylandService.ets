import wl from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { ToolEnvStore, UiPrefs } from '../model/ToolEnvStore';
import { window, display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

export interface WlBufferSize {
  w: number;
  h: number;
}

export interface AutoHostWindowConfig {
  appIdPrefix: string;
  fallbackTitle: string;
  loadPage: string;            // 通常 'pages/AppRunner'
  onWindowCreated?: (win: window.Window, appId: string) => void;
  onWindowDestroyed?: (appId: string) => void;
}

const ACTIVE_TIMEOUT_MS: number = 15000;

export class WaylandService {
  private static instance: WaylandService | null = null;
  private ctx: common.UIAbilityContext | null = null;
  private autoWindowConfig: AutoHostWindowConfig | null = null;
  private autoWindowSeq: number = 0;
  private autoWindows: Map<string, window.Window> = new Map();

  static getInstance(): WaylandService {
    if (!WaylandService.instance) {
      WaylandService.instance = new WaylandService();
    }
    return WaylandService.instance;
  }

  // ===== state =====
  private serverReady: boolean = false;
  private sockPath: string = '';
  private currentAppId: string | null = null;
  private activeWaiter: ((ok: boolean) => void) | null = null;

  // ===== UI prefs =====
  private uiScale: number = 1.0;
  private useNativeDecor: boolean = true;

  // ===== listeners =====
  private sizeListener: ((w: number, h: number) => void) | null = null;
  private moveListener: (() => void) | null = null;
  private exitListener: (() => void) | null = null;
  private maximizeListener: (() => void) | null = null;
  private unmaximizeListener: (() => void) | null = null;
  private resizeListener: ((edges: number) => void) | null = null;
  private minimizeListener: (() => void) | null = null;
  private hostResizeBeginListener: ((edges: number) => void) | null = null;
  private hostResizeDragListener:
  ((edges: number, dxPx: number, dyPx: number) => void) | null = null;
  private hostResizeEndListener: (() => void) | null = null;
  private autoActiveListener: (() => void) | null = null;

  // =========================================================
  // lifecycle
  // =========================================================
  init(ctx: common.UIAbilityContext, autoWindow?: AutoHostWindowConfig): boolean {
    if (this.serverReady) return true;

    this.ctx = ctx;
    if (autoWindow) this.autoWindowConfig = autoWindow;

    this.sockPath = `${ctx.filesDir}/wl-sock`;

    const prefs: UiPrefs = ToolEnvStore.loadUiPrefs(ctx);
    this.uiScale = prefs.scale;
    this.useNativeDecor = prefs.useNativeDecor;

    wl.setStateCallback((s: string): void => {
      console.info(`[WL] state=${s}`);
      if (s === 'active') {
        if (this.activeWaiter) {
          const w = this.activeWaiter;
          this.activeWaiter = null;
          w(true);
        } else if (this.autoActiveListener) {
          this.autoActiveListener();
        }
      }
      if (s === 'exited' && this.exitListener) {
        this.exitListener();
      }
    });

    wl.setSizeCallback((w: number, h: number): void => {
      if (this.sizeListener) this.sizeListener(w, h);
    });
    wl.setMoveCallback((): void => {
      if (this.moveListener) this.moveListener();
    });
    wl.setMaximizeCallback((): void => {
      if (this.maximizeListener) this.maximizeListener();
    });
    wl.setUnmaximizeCallback((): void => {
      if (this.unmaximizeListener) this.unmaximizeListener();
    });
    wl.setResizeCallback((edges: number): void => {
      if (this.resizeListener) this.resizeListener(edges);
    });
    wl.setMinimizeCallback((): void => {
      if (this.minimizeListener) this.minimizeListener();
    });

    const ok: boolean = wl.startWaylandServer(this.sockPath);
    this.serverReady = ok;
    return ok;
  }

  shutdown(): void {
    if (!this.serverReady) return;
    try { wl.stopAll(); } catch (e) { /* ignore */ }
    this.serverReady = false;
    this.currentAppId = null;
    this.activeWaiter = null;
  }

  // =========================================================
  // state queries
  // =========================================================
  isServerReady(): boolean { return this.serverReady; }
  getCurrentAppId(): string | null { return this.currentAppId; }
  getSockPath(): string { return this.sockPath; }

  // =========================================================
  // UI prefs
  // =========================================================
  getUiScale(): number { return this.uiScale; }
  getUseNativeDecor(): boolean { return this.useNativeDecor; }

  reloadUiPrefs(ctx: common.Context): void {
    const prefs: UiPrefs = ToolEnvStore.loadUiPrefs(ctx);
    this.uiScale = prefs.scale;
    this.useNativeDecor = prefs.useNativeDecor;
  }

  // =========================================================
  // wayland env (供 CliService 在 GUI 模式下注入)
  // =========================================================
  getWaylandEnv(): string[] {
    if (!this.sockPath) return [];
    const idx: number = this.sockPath.lastIndexOf('/');
    const dir: string = idx >= 0 ? this.sockPath.substring(0, idx) : '/tmp';
    const name: string = idx >= 0 ? this.sockPath.substring(idx + 1) : this.sockPath;
    return [
      `WAYLAND_DISPLAY=${name}`,
      `XDG_RUNTIME_DIR=${dir}`,
      `HOME=${dir}`
    ];
  }

  // =========================================================
  // GUI slot
  // =========================================================
  claimSlot(appId: string): boolean {
    if (!this.serverReady) return false;
    if (this.currentAppId) return false;
    this.currentAppId = appId;
    return true;
  }

  // CliService 在 GUI 进程退出时调用,等价于原来 C++ state="exited" 走的路径
  fireGuiExit(appId: string): void {
    if (this.currentAppId === appId && this.exitListener) {
      this.exitListener();
    }
  }

  // 释放槽位:同时杀掉 launchClient 跟踪的单例 GUI client。
  // launchCli (streaming) 启动的进程不在 g_clientPid 里,本调用对它无影响,
  // 调用方需要自己再 cliSvc.stop(pid)。
  releaseSlot(appId: string): void {
    if (this.currentAppId !== appId) return;
    this.currentAppId = null;
    this.activeWaiter = null;
    // try { wl.stopClient(); } catch (e) { /* ignore */ }
  }

  waitActive(timeoutMs: number = ACTIVE_TIMEOUT_MS): Promise<boolean> {
    return new Promise((resolve: (v: boolean) => void): void => {
      let resolved: boolean = false;
      this.activeWaiter = (ok: boolean): void => {
        if (resolved) return;
        resolved = true;
        resolve(true);
      };
      setTimeout((): void => {
        if (resolved) return;
        resolved = true;
        this.activeWaiter = null;
        resolve(false);
      }, timeoutMs);
    });
  }

  // =========================================================
  // listeners (套薄壳保留旧 API,内部一行转发)
  // =========================================================
  setSizeListener(cb: ((w: number, h: number) => void) | null): void {
    this.sizeListener = cb;
  }
  setMoveListener(cb: (() => void) | null): void { this.moveListener = cb; }
  setExitListener(cb: (() => void) | null): void { this.exitListener = cb; }
  setMaximizeListener(cb: (() => void) | null): void { this.maximizeListener = cb; }
  setUnmaximizeListener(cb: (() => void) | null): void { this.unmaximizeListener = cb; }
  setResizeListener(cb: ((edges: number) => void) | null): void { this.resizeListener = cb; }
  setMinimizeListener(cb: (() => void) | null): void { this.minimizeListener = cb; }

  setHostResizeBeginListener(cb: ((edges: number) => void) | null): void {
    this.hostResizeBeginListener = cb;
  }
  setHostResizeDragListener(
    cb: ((edges: number, dxPx: number, dyPx: number) => void) | null
  ): void {
    this.hostResizeDragListener = cb;
  }
  setHostResizeEndListener(cb: (() => void) | null): void {
    this.hostResizeEndListener = cb;
  }

  setAutoActiveListener(cb: (() => void) | null): void {
    this.autoActiveListener = cb;
  }

  fireHostResizeBegin(edges: number): void {
    if (this.hostResizeBeginListener) this.hostResizeBeginListener(edges);
  }
  notifyHostResizeDrag(edges: number, dxPx: number, dyPx: number): void {
    if (this.hostResizeDragListener) this.hostResizeDragListener(edges, dxPx, dyPx);
  }
  notifyHostResizeEnd(): void {
    if (this.hostResizeEndListener) this.hostResizeEndListener();
  }

  // =========================================================
  // buffer / configure
  // =========================================================
  getLatestBufferSize(): WlBufferSize {
    try {
      return wl.getLatestSize() as WlBufferSize;
    } catch (e) {
      return { w: 0, h: 0 };
    }
  }

  requestClientResize(bufW: number, bufH: number, maximized: boolean): void {
    try {
      wl.requestClientResize(bufW, bufH, maximized);
    } catch (e) { /* ignore */ }
  }

  //
  enableAutoHostWindow(config: AutoHostWindowConfig): void {
    this.autoWindowConfig = config;
  }

  disableAutoHostWindow(): void {
    this.autoWindowConfig = null;
  }

  isAutoHostWindowEnabled(): boolean {
    return this.autoWindowConfig !== null;
  }

  private async autoCreateHostWindow(): Promise<void> {
    const config: AutoHostWindowConfig | null = this.autoWindowConfig;
    if (!config || !this.ctx) return;

    const appId: string = `${config.appIdPrefix}-${++this.autoWindowSeq}`;
    if (!this.claimSlot(appId)) {
      console.warn('HBOX_WL_AUTO_WIN_SKIP slot taken');
      return;
    }

    const stashedName: string | undefined = AppStorage.get<string>('currentAppName');
    const title: string = (stashedName && stashedName.length > 0)
      ? stashedName : config.fallbackTitle;

    try {
      const windowStage: window.WindowStage | undefined =
        AppStorage.get<window.WindowStage>('windowStage');
      if (!windowStage) {
        console.error('HBOX_WL_AUTO_WIN_NO_STAGE');
        this.releaseSlot(appId);
        return;
      }
      const main: window.Window = windowStage.getMainWindowSync();

      AppStorage.setOrCreate<string>('currentAppName', title);

      const useNative: boolean = this.useNativeDecor;
      const subWin: window.Window = await main.createSubWindowWithOptions(
        `auto_${appId}_${Date.now()}`,
        { title, decorEnabled: useNative, isModal: false, maximizeSupported: true }
      );
      await subWin.loadContent(config.loadPage);

      const sz: WlBufferSize = this.getLatestBufferSize();
      const bufW: number = sz.w > 0 ? sz.w : 800;
      const bufH: number = sz.h > 0 ? sz.h : 600;
      const scale: number = this.uiScale;
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

      subWin.on('windowEvent', (event: window.WindowEventType): void => {
        if (event === window.WindowEventType.WINDOW_DESTROYED) {
          this.autoWindows.delete(appId);
          this.releaseSlot(appId);
          if (config.onWindowDestroyed) config.onWindowDestroyed(appId);
          console.info(`HBOX_WL_AUTO_WIN_DESTROYED app=${appId}`);
        }
      });

      this.autoWindows.set(appId, subWin);
      await subWin.showWindow();
      console.info(`HBOX_WL_AUTO_WIN_SHOWN app=${appId} ${totalW}x${totalH}`);
      if (config.onWindowCreated) config.onWindowCreated(subWin, appId);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`HBOX_WL_AUTO_WIN_FAIL code=${err.code} msg=${err.message}`);
      this.releaseSlot(appId);
    }
  }
}