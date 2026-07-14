import wl from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { ToolEnvStore, UiPrefs } from '../model/ToolEnvStore';

export interface WlBufferSize {
  w: number;
  h: number;
}

// clientId 为将来多 client 预留. 当前 C++ 侧只支持单 client, 统一用 'c0'
const DEFAULT_CLIENT_ID: string = 'c0';

export type ClientIdListener = (clientId: string) => void;
export type ClientCommitListener = (clientId: string, w: number, h: number) => void;
export type ClientResizeListener = (clientId: string, edges: number) => void;
export type HostResizeDragListener = (edges: number, dxPx: number, dyPx: number) => void;

export class WaylandService {
  private static instance: WaylandService | null = null;
  static getInstance(): WaylandService {
    if (!WaylandService.instance) {
      WaylandService.instance = new WaylandService();
    }
    return WaylandService.instance;
  }

  // unused
  // private ctx: common.UIAbilityContext | null = null;

  // ===== state =====
  private serverReady: boolean = false;
  private sockPath: string = '';

  // ===== UI prefs =====
  private uiScale: number = 1.0;
  private useNativeDecor: boolean = true;

  // ===== client event listeners =====
  private connectListener:    ClientIdListener | null = null;
  private disconnectListener: ClientIdListener | null = null;
  private commitListener:     ClientCommitListener | null = null;
  private moveListener:       ClientIdListener | null = null;
  private resizeListener:     ClientResizeListener | null = null;
  private maximizeListener:   ClientIdListener | null = null;
  private unmaximizeListener: ClientIdListener | null = null;
  private minimizeListener:   ClientIdListener | null = null;

  // ===== host-side resize drag =====
  private hostResizeBeginListener: ((edges: number) => void) | null = null;
  private hostResizeDragListener:  HostResizeDragListener | null = null;
  private hostResizeEndListener:   (() => void) | null = null;

  // =========================================================
  // lifecycle
  // =========================================================
  init(ctx: common.UIAbilityContext): boolean {
    if (this.serverReady) return true;
    // this.ctx = ctx;
    this.sockPath = `${ctx.filesDir}/wl-sock`;

    const prefs: UiPrefs = ToolEnvStore.loadUiPrefs(ctx);
    this.uiScale = prefs.scale;
    this.useNativeDecor = prefs.useNativeDecor;

    // 'active' = 客户端连上; 'exited' = 客户端退出
    wl.setStateCallback((s: string): void => {
      console.info(`[WL] state=${s}`);
      if (s === 'active') {
        if (this.connectListener) this.connectListener(DEFAULT_CLIENT_ID);
      } else if (s === 'exited') {
        if (this.disconnectListener) this.disconnectListener(DEFAULT_CLIENT_ID);
      }
    });
    wl.setSizeCallback((w: number, h: number): void => {
      if (this.commitListener) this.commitListener(DEFAULT_CLIENT_ID, w, h);
    });
    wl.setMoveCallback((): void => {
      if (this.moveListener) this.moveListener(DEFAULT_CLIENT_ID);
    });
    wl.setMaximizeCallback((): void => {
      if (this.maximizeListener) this.maximizeListener(DEFAULT_CLIENT_ID);
    });
    wl.setUnmaximizeCallback((): void => {
      if (this.unmaximizeListener) this.unmaximizeListener(DEFAULT_CLIENT_ID);
    });
    wl.setResizeCallback((edges: number): void => {
      if (this.resizeListener) this.resizeListener(DEFAULT_CLIENT_ID, edges);
    });
    wl.setMinimizeCallback((): void => {
      if (this.minimizeListener) this.minimizeListener(DEFAULT_CLIENT_ID);
    });

    const ok: boolean = wl.startWaylandServer(this.sockPath);
    this.serverReady = ok;
    return ok;
  }

  shutdown(): void {
    if (!this.serverReady) return;
    try { wl.stopAll(); } catch (e) { /* ignore */ }
    this.serverReady = false;
  }

  // =========================================================
  // state queries
  // =========================================================
  isServerReady(): boolean { return this.serverReady; }
  getSockPath():   string  { return this.sockPath; }

  getUiScale():        number  { return this.uiScale; }
  getUseNativeDecor(): boolean { return this.useNativeDecor; }
  reloadUiPrefs(ctx: common.Context): void {
    const prefs: UiPrefs = ToolEnvStore.loadUiPrefs(ctx);
    this.uiScale = prefs.scale;
    this.useNativeDecor = prefs.useNativeDecor;
  }

  getWaylandEnv(): string[] {
    if (!this.sockPath) return [];
    const idx: number = this.sockPath.lastIndexOf('/');
    const dir: string  = idx >= 0 ? this.sockPath.substring(0, idx) : '/tmp';
    const name: string = idx >= 0 ? this.sockPath.substring(idx + 1) : this.sockPath;
    return [
      `WAYLAND_DISPLAY=${name}`,
      `XDG_RUNTIME_DIR=${dir}`,
      `HOME=${dir}`
    ];
  }

  // =========================================================
  // client event listeners
  // =========================================================
  setClientConnectListener(cb: ClientIdListener | null):     void { this.connectListener = cb; }
  setClientDisconnectListener(cb: ClientIdListener | null):  void { this.disconnectListener = cb; }
  setClientCommitListener(cb: ClientCommitListener | null):  void { this.commitListener = cb; }
  setClientMoveListener(cb: ClientIdListener | null):        void { this.moveListener = cb; }
  setClientResizeListener(cb: ClientResizeListener | null):  void { this.resizeListener = cb; }
  setClientMaximizeListener(cb: ClientIdListener | null):    void { this.maximizeListener = cb; }
  setClientUnmaximizeListener(cb: ClientIdListener | null):  void { this.unmaximizeListener = cb; }
  setClientMinimizeListener(cb: ClientIdListener | null):    void { this.minimizeListener = cb; }

  // =========================================================
  // host-side resize drag
  // =========================================================
  setHostResizeBeginListener(cb: ((edges: number) => void) | null): void {
    this.hostResizeBeginListener = cb;
  }
  setHostResizeDragListener(cb: HostResizeDragListener | null): void {
    this.hostResizeDragListener = cb;
  }
  setHostResizeEndListener(cb: (() => void) | null): void {
    this.hostResizeEndListener = cb;
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
  // buffer / configure  (clientId 预留)
  // =========================================================
  getLatestBufferSize(_clientId?: string): WlBufferSize {
    try {
      return wl.getLatestSize() as WlBufferSize;
    } catch (e) {
      return { w: 0, h: 0 };
    }
  }

  requestClientResize(_clientId: string, bufW: number, bufH: number, maximized: boolean): void {
    try {
      wl.requestClientResize(bufW, bufH, maximized);
    } catch (e) { /* ignore */ }
  }
}