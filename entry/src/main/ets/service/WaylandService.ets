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
type ClientConnectListener = (cid: string, instanceId: string) => void;

export class WaylandService {
  private static instance: WaylandService | null = null;
  static getInstance(): WaylandService {
    if (!WaylandService.instance) {
      WaylandService.instance = new WaylandService();
    }
    return WaylandService.instance;
  }

  private ctx: common.UIAbilityContext | null = null;

  // ===== state =====
  private serverReady: boolean = false;
  private sockPath: string = '';

  // ===== UI prefs =====
  private uiScale: number = 1.0;
  private useNativeDecor: boolean = true;

  // ===== client event listeners =====
  private connectListener:    ClientConnectListener | null = null;
  private disconnectListener: ClientIdListener | null = null;
  private commitListener:     ClientCommitListener | null = null;
  private moveListener:       ClientIdListener | null = null;
  private resizeListener:     ClientResizeListener | null = null;
  private maximizeListener:   ClientIdListener | null = null;
  private unmaximizeListener: ClientIdListener | null = null;
  private minimizeListener:   ClientIdListener | null = null;

  // ===== host-side resize drag =====
  private hostResizeBeginListeners: Map<string, (edges: number) => void> = new Map();
  private hostResizeDragListener:  HostResizeDragListener | null = null;
  private hostResizeEndListener:   (() => void) | null = null;



  // =========================================================
  // lifecycle
  // =========================================================
  init(ctx: common.UIAbilityContext): boolean {
    if (this.serverReady) return true;
    this.ctx = ctx;
    this.sockPath = `${ctx.filesDir}/wl-sock`;

    const prefs: UiPrefs = ToolEnvStore.loadUiPrefs(ctx);
    this.uiScale = prefs.scale;
    this.useNativeDecor = prefs.useNativeDecor;

    // ★ 新: 显式带 clientId
    wl.setClientConnectCallback((cid: string, instanceId: string): void => {
      console.info(`[WL] connect cid=${cid} inst=${instanceId}`);
      if (this.connectListener) this.connectListener(cid, instanceId);
    });
    wl.setClientDisconnectCallback((cid: string): void => {
      console.info(`[WL] disconnect cid=${cid}`);
      if (this.disconnectListener) this.disconnectListener(cid);
    });

    // sizeCallback 现在带 cid
    wl.setSizeCallback((cid: string, w: number, h: number): void => {
      if (this.commitListener) this.commitListener(cid, w, h);
    });

    // init() 里全部改成透传 cid, 不再用 DEFAULT_CLIENT_ID
    wl.setMoveCallback((cid: string): void => {
      if (this.moveListener) this.moveListener(cid);
    });
    wl.setMaximizeCallback((cid: string): void => {
      if (this.maximizeListener) this.maximizeListener(cid);
    });
    wl.setUnmaximizeCallback((cid: string): void => {
      if (this.unmaximizeListener) this.unmaximizeListener(cid);
    });
    wl.setResizeCallback((cid: string, edges: number): void => {
      if (this.resizeListener) this.resizeListener(cid, edges);
    });
    wl.setMinimizeCallback((cid: string): void => {
      if (this.minimizeListener) this.minimizeListener(cid);
    });

    // ★ setStateCallback 桥接删除
    // wl.setStateCallback((s: string): void => {
    //     if (s === 'active')      this.connectListener?.(DEFAULT_CLIENT_ID);
    //     else if (s === 'exited') this.disconnectListener?.(DEFAULT_CLIENT_ID);
    // });

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
  setClientConnectListener(cb: ClientConnectListener | null): void { this.connectListener = cb; }
  setClientDisconnectListener(cb: ClientIdListener | null):   void { this.disconnectListener = cb; }
  setClientCommitListener(cb: ClientCommitListener | null):   void { this.commitListener = cb; }
  setClientMoveListener(cb: ClientIdListener | null):         void { this.moveListener = cb; }
  setClientResizeListener(cb: ClientResizeListener | null):   void { this.resizeListener = cb; }
  setClientMaximizeListener(cb: ClientIdListener | null):     void { this.maximizeListener = cb; }
  setClientUnmaximizeListener(cb: ClientIdListener | null):   void { this.unmaximizeListener = cb; }
  setClientMinimizeListener(cb: ClientIdListener | null):     void { this.minimizeListener = cb; }

  // =========================================================
  // host-side resize drag
  // =========================================================
  setHostResizeBeginListener(clientId: string, cb: ((edges: number) => void) | null): void {
    if (cb) this.hostResizeBeginListeners.set(clientId, cb);
    else this.hostResizeBeginListeners.delete(clientId);
  }
  setHostResizeDragListener(cb: HostResizeDragListener | null): void {
    this.hostResizeDragListener = cb;
  }
  setHostResizeEndListener(cb: (() => void) | null): void {
    this.hostResizeEndListener = cb;
  }

  fireHostResizeBegin(clientId: string, edges: number): void {
    const cb = this.hostResizeBeginListeners.get(clientId);
    if (cb) cb(edges);
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
  getLatestBufferSize(clientId: string): WlBufferSize {
    if (!clientId) return { w: 0, h: 0 };
    try {
      return wl.getLatestSize(clientId) as WlBufferSize;
    } catch (e) {
      return { w: 0, h: 0 };
    }
  }

  requestClientResize(clientId: string, bufW: number, bufH: number, maximized: boolean): void {
    if (!clientId) return;
    try {
      wl.requestClientResize(clientId, bufW, bufH, maximized);
    } catch (e) {
      console.warn('requestClientResize failed', e);
    }
  }
}