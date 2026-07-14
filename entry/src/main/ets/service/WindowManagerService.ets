import { window, display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { WaylandService, WlBufferSize } from './WaylandService';
import { ProcessManagerService } from './ProcessManagerService';

// =========================================================
// types
// =========================================================

interface MovableWindow { startMoving?: () => Promise<void>; }
interface RestorableWindow {
  showWindow?:    () => Promise<void>;
  raiseToAppTop?: () => Promise<void>;
}
interface HostSize { w: number; h: number; x: number; y: number; }
interface ResizeStart {
  edges:  number;
  startX: number; startY: number;
  startW: number; startH: number;
}

interface PendingLaunch {
  instanceId: string;
  appName:    string;
  appId:      string;
  createdAt:  number;
}

export interface AppInstance {
  instanceId: string;
  appId:      string;              // 空表示 auto 实例 (shell 里手动起的)
  appName:    string;
  pid:        number;
  clientId:   string | null;
  hostWindow: window.Window | null;
  logWindow:  window.Window | null;
  createdAt:  number;
}

const PENDING_TTL_MS: number = 15000;

export type RunningIdsListener = (ids: string[]) => void;
export type InstancesListener  = (list: AppInstance[]) => void;

// =========================================================
// WindowManagerService
// =========================================================

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

  // 实例索引
  private instances:   Map<string, AppInstance> = new Map();  // instanceId → instance
  private clientIndex: Map<string, string>      = new Map();  // clientId   → instanceId
  private appIndex:    Map<string, string[]>    = new Map();  // appId      → [instanceId]

  // 预登记队列 (FIFO)
  private pendingQueue: PendingLaunch[] = [];

  // auto 实例序号
  private autoSeq: number = 0;

  // running listener
  private runningAppIds: string[] = [];
  private runningIdsListener: RunningIdsListener | null = null;
  private instancesListener:  InstancesListener  | null = null;

  // 窗口调整状态 (以 instanceId 为键)
  private firstCommitDone: Set<string>            = new Set();
  private maximizedInsts:  Set<string>            = new Set();
  private savedHostSizes:  Map<string, HostSize>  = new Map();
  private maxOpUntil:               number = 0;
  private resizeDebounceTimer:      number = -1;
  private resizeStart:              ResizeStart | null = null;
  private resizeDragLastConfigure:  number = 0;
  private resizingInstanceId:       string | null = null;

  // =========================================================
  // lifecycle
  // =========================================================

  init(ctx: common.UIAbilityContext): void {
    this.ctx = ctx;
    if (this.installed) return;

    const wlSvc = WaylandService.getInstance();
    wlSvc.init(ctx);

    wlSvc.setClientConnectListener((cid: string): void => {
      this.handleClientConnect(cid);
    });
    wlSvc.setClientDisconnectListener((cid: string): void => {
      this.handleClientDisconnect(cid);
    });
    wlSvc.setClientCommitListener((cid: string, w: number, h: number): void => {
      this.handleClientCommit(cid, w, h);
    });
    wlSvc.setClientMoveListener((cid: string): void => {
      this.handleClientMove(cid);
    });
    wlSvc.setClientResizeListener((cid: string, edges: number): void => {
      this.handleClientResize(cid, edges);
    });
    wlSvc.setClientMaximizeListener((cid: string): void => {
      this.handleClientMaximize(cid);
    });
    wlSvc.setClientUnmaximizeListener((cid: string): void => {
      this.handleClientUnmaximize(cid);
    });
    wlSvc.setClientMinimizeListener((cid: string): void => {
      this.handleClientMinimize(cid);
    });
    wlSvc.setHostResizeDragListener((edges: number, dxPx: number, dyPx: number): void => {
      this.handleHostResizeDrag(edges, dxPx, dyPx);
    });
    wlSvc.setHostResizeEndListener((): void => {
      this.handleHostResizeEnd();
    });

    this.installed = true;
  }

  shutdown(): void {
    WaylandService.getInstance().shutdown();
  }

  // =========================================================
  // listeners
  // =========================================================

  setRunningIdsListener(cb: RunningIdsListener | null): void {
    this.runningIdsListener = cb;
    if (cb) cb(this.runningAppIds.slice());
  }

  setInstancesListener(cb: InstancesListener | null): void {
    this.instancesListener = cb;
    if (cb) cb(Array.from(this.instances.values()));
  }

  // =========================================================
  // API: 由 ProcessManagerService 调用
  // =========================================================

  /** 预登记: 起进程前调用, 等 wayland client 连上后从队列头部取匹配 */
  registerPending(instanceId: string, appName: string, appId: string): void {
    this.pendingQueue.push({
      instanceId, appName, appId, createdAt: Date.now()
    });
    this.pruneExpiredPending();
  }

  /** 取消预登记 (spawn 失败时) */
  cancelPending(instanceId: string): void {
    this.pendingQueue = this.pendingQueue.filter(
      (p: PendingLaunch): boolean => p.instanceId !== instanceId
    );
  }

  /** 绑定 pid (spawn 成功后立即调用) */
  bindPid(instanceId: string, pid: number): void {
    const inst = this.ensureInstance(instanceId, '', '', pid);
    inst.pid = pid;
  }

  /** 进程退出通知 (由 ProcessManagerService 的 subscribe 回调转发) */
  onProcessExit(instanceId: string, _code: number): void {
    const inst = this.instances.get(instanceId);
    if (!inst) return;
    // 客户端已经先断了 → 窗口也没了 → 现在清数据
    if (inst.hostWindow === null && inst.logWindow === null) {
      this.cleanupInstance(instanceId);
    }
    // 否则等 disconnect 事件或用户手动关窗
  }

  /** 创建日志窗口 (streaming stdout/exit) */
  async createLogWindow(instanceId: string, appName: string, pid: number): Promise<void> {
    AppStorage.setOrCreate<string>('currentAppName', appName);
    AppStorage.setOrCreate<number>('currentCliPid', pid);
    try {
      const windowStage = AppStorage.get<window.WindowStage>('windowStage');
      if (!windowStage) {
        console.error('HBOX_WM_LOG_NO_STAGE');
        return;
      }
      const main = windowStage.getMainWindowSync();

      const inst = this.ensureInstance(instanceId, appName, '', pid);
      const attachedToGui: boolean =
        inst.hostWindow !== null || inst.clientId !== null;
      const title: string = attachedToGui
        ? `${appName} (日志)`
        : `${appName} (CLI)`;

      const subWin: window.Window = await main.createSubWindowWithOptions(
        `log_${instanceId}_${Date.now()}`,
        { title, decorEnabled: true, isModal: false }
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

      subWin.on('windowEvent', (event: window.WindowEventType): void => {
        if (event === window.WindowEventType.WINDOW_DESTROYED) {
          const cur = this.instances.get(instanceId);
          if (cur) cur.logWindow = null;
          ProcessManagerService.getInstance().terminate(pid);
          if (cur && cur.hostWindow === null) {
            this.cleanupInstance(instanceId);
          }
        }
      });

      inst.logWindow = subWin;
      this.notifyChanged();
      await subWin.showWindow();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`createLogWindow failed: ${err.code}, ${err.message}`);
      ProcessManagerService.getInstance().terminate(pid);
    }
  }

  // =========================================================
  // API: 外部销毁 / 恢复
  // =========================================================

  /** 主动销毁一个实例 (关窗口 + 停进程 + 清数据) */
  destroyInstance(instanceId: string): void {
    const inst: AppInstance | undefined = this.instances.get(instanceId);
    if (!inst) return;
    if (inst.hostWindow) {
      inst.hostWindow.destroyWindow().catch((): void => { /* ignore */ });
      inst.hostWindow = null;
    }
    if (inst.logWindow) {
      inst.logWindow.destroyWindow().catch((): void => { /* ignore */ });
      inst.logWindow = null;
    }
    if (inst.pid > 0) {
      ProcessManagerService.getInstance().terminate(inst.pid);
    }
    this.cleanupInstance(instanceId);
  }

  /** 销毁某 app 的所有实例 */
  destroyAllOfApp(appId: string): void {
    const ids: string[] | undefined = this.appIndex.get(appId);
    if (!ids) return;
    for (const id of [...ids]) this.destroyInstance(id);
  }

  /** 尝试恢复已有窗口 (点击已在跑的应用时先调这个) */
  async bringToFront(appId: string): Promise<boolean> {
    const ids: string[] | undefined = this.appIndex.get(appId);
    if (!ids || ids.length === 0) return false;
    const first: AppInstance | undefined = this.instances.get(ids[0]);
    const win = first?.hostWindow ?? first?.logWindow;
    if (!win) return false;
    const r: RestorableWindow = win as RestorableWindow;
    if (!r.showWindow) return false;
    try {
      await r.showWindow();
      if (r.raiseToAppTop) await r.raiseToAppTop();
      return true;
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`HBOX_WM_RESTORE_FAIL code=${err.code} msg=${err.message}`);
      return false;
    }
  }

  // =========================================================
  // client event handlers (来自 wayland)
  // =========================================================

  private handleClientConnect(clientId: string): void {
    this.pruneExpiredPending();
    const pending: PendingLaunch | undefined = this.pendingQueue.shift();

    let instanceId: string;
    let appName:    string;
    let appId:      string;

    if (pending) {
      instanceId = pending.instanceId;
      appName    = pending.appName;
      appId      = pending.appId;
    } else {
      // shell 里手动起的 wine, 无预登记 → auto 实例
      instanceId = `auto-${++this.autoSeq}`;
      const stashed: string | undefined = AppStorage.get<string>('currentAppName');
      appName = (stashed && stashed.length > 0) ? stashed : 'External App';
      appId   = '';
    }

    const inst = this.ensureInstance(instanceId, appName, appId, 0);
    inst.clientId = clientId;
    this.clientIndex.set(clientId, instanceId);

    this.createHostWindow(inst).catch((e: BusinessError): void => {
      console.error(`HBOX_WM_HOST_CREATE_FAIL code=${e.code} msg=${e.message}`);
    });
  }

  private handleClientDisconnect(clientId: string): void {
    const instanceId: string | undefined = this.clientIndex.get(clientId);
    if (!instanceId) return;
    const inst: AppInstance | undefined = this.instances.get(instanceId);
    if (!inst) return;

    if (inst.hostWindow) {
      inst.hostWindow.destroyWindow().catch((): void => { /* ignore */ });
      inst.hostWindow = null;
    }
    this.clientIndex.delete(clientId);
    inst.clientId = null;

    // 日志窗口保留 (用户可能想看退出后的日志); 无日志窗口时直接清
    if (inst.logWindow === null) {
      this.cleanupInstance(instanceId);
    }
  }

  private handleClientCommit(clientId: string, bufW: number, bufH: number): void {
    if (bufW <= 0 || bufH <= 0) return;
    const inst = this.getInstanceByClient(clientId);
    if (!inst || !inst.hostWindow) return;
    if (this.firstCommitDone.has(inst.instanceId)) return;

    this.firstCommitDone.add(inst.instanceId);
    this.applyWindowSize(inst.hostWindow, bufW, bufH);
  }

  private handleClientMove(clientId: string): void {
    const inst = this.getInstanceByClient(clientId);
    if (!inst || !inst.hostWindow) return;
    try {
      const movable: MovableWindow = inst.hostWindow as MovableWindow;
      if (movable.startMoving) {
        movable.startMoving().catch((e: BusinessError): void => {
          console.error(`startMoving failed: ${e.code} ${e.message}`);
        });
      }
    } catch (e) {
      console.error(`handleClientMove failed: ${JSON.stringify(e)}`);
    }
  }

  private handleClientMaximize(clientId: string): void {
    const inst = this.getInstanceByClient(clientId);
    if (!inst || !inst.hostWindow) return;
    if (this.maximizedInsts.has(inst.instanceId)) return;
    this.maximizedInsts.add(inst.instanceId);

    try {
      const r = inst.hostWindow.getWindowProperties().windowRect;
      this.savedHostSizes.set(inst.instanceId,
        { w: r.width, h: r.height, x: r.left, y: r.top });
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

    this.sendConfigure(clientId, availW, availH, true);
    const win = inst.hostWindow;
    win.resize(availW, availH).then((): void => {
      win.moveWindowToGlobal(0, 0).catch((): void => { /* ignore */ });
    }).catch((e: BusinessError): void => {
      console.warn(`HBOX_WIN_MAX_FAIL code=${e.code}`);
    });
  }

  private handleClientUnmaximize(clientId: string): void {
    const inst = this.getInstanceByClient(clientId);
    if (!inst || !inst.hostWindow) return;
    if (!this.maximizedInsts.has(inst.instanceId)) return;
    this.maximizedInsts.delete(inst.instanceId);

    this.maxOpUntil = Date.now() + 1000;
    const saved: HostSize | undefined = this.savedHostSizes.get(inst.instanceId);
    this.savedHostSizes.delete(inst.instanceId);
    if (!saved) return;

    this.sendConfigure(clientId, saved.w, saved.h, false);
    const win = inst.hostWindow;
    win.resize(saved.w, saved.h).then((): void => {
      win.moveWindowToGlobal(saved.x, saved.y).catch((): void => { /* ignore */ });
    }).catch((e: BusinessError): void => {
      console.warn(`HBOX_WIN_UNMAX_FAIL code=${e.code}`);
    });
  }

  private handleClientMinimize(clientId: string): void {
    const inst = this.getInstanceByClient(clientId);
    if (!inst || !inst.hostWindow) return;
    inst.hostWindow.minimize().catch((e: BusinessError): void => {
      console.warn(`HBOX_WIN_MIN_FAIL code=${e.code} msg=${e.message}`);
    });
  }

  private handleClientResize(clientId: string, edges: number): void {
    const inst = this.getInstanceByClient(clientId);
    if (!inst || !inst.hostWindow) return;
    try {
      const r = inst.hostWindow.getWindowProperties().windowRect;
      this.resizeStart = {
        edges,
        startX: r.left, startY: r.top,
        startW: r.width, startH: r.height
      };
      this.resizingInstanceId = inst.instanceId;
      WaylandService.getInstance().fireHostResizeBegin(edges);
    } catch (e) {
      console.warn(`HBOX_WIN_RESIZE_INIT_FAIL ${JSON.stringify(e)}`);
    }
  }

  // =========================================================
  // host-side resize drag
  // =========================================================

  private handleHostResizeDrag(edges: number, dxPx: number, dyPx: number): void {
    if (!this.resizeStart || !this.resizingInstanceId) return;
    const s: ResizeStart = this.resizeStart;
    const inst = this.instances.get(this.resizingInstanceId);
    if (!inst || !inst.hostWindow || !inst.clientId) return;

    let newX = s.startX, newY = s.startY;
    let newW = s.startW, newH = s.startH;
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

    const win = inst.hostWindow;
    win.resize(newW, newH).then((): void => {
      win.moveWindowToGlobal(newX, newY).catch((): void => { /* ignore */ });
    }).catch((e: BusinessError): void => {
      console.warn(`HBOX_WIN_RESIZE_DRAG_FAIL code=${e.code}`);
    });

    const now = Date.now();
    if (now - this.resizeDragLastConfigure >= 80) {
      this.resizeDragLastConfigure = now;
      this.sendConfigure(inst.clientId, newW, newH, false);
    }
  }

  private handleHostResizeEnd(): void {
    if (this.resizingInstanceId) {
      const inst = this.instances.get(this.resizingInstanceId);
      if (inst && inst.hostWindow && inst.clientId) {
        try {
          const r = inst.hostWindow.getWindowProperties().windowRect;
          this.sendConfigure(inst.clientId, r.width, r.height, false);
        } catch (e) { /* ignore */ }
      }
    }
    this.resizeStart = null;
    this.resizingInstanceId = null;
    this.resizeDragLastConfigure = 0;
    this.maxOpUntil = Date.now() + 300;
  }

  private handleHostSizeChange(instanceId: string, hostW: number, hostH: number): void {
    if (!this.firstCommitDone.has(instanceId)) return;
    if (hostW <= 0 || hostH <= 0) return;
    if (Date.now() < this.maxOpUntil) return;
    const inst = this.instances.get(instanceId);
    if (!inst || !inst.clientId) return;

    if (this.resizeDebounceTimer >= 0) clearTimeout(this.resizeDebounceTimer);
    this.resizeDebounceTimer = setTimeout((): void => {
      this.resizeDebounceTimer = -1;
      const maximized: boolean = this.maximizedInsts.has(instanceId);
      const clientId: string | null = inst.clientId;
      if (clientId) this.sendConfigure(clientId, hostW, hostH, maximized);
    }, 150);
  }

  // =========================================================
  // host window creation (统一入口)
  // =========================================================

  private async createHostWindow(inst: AppInstance): Promise<void> {
    try {
      const windowStage = AppStorage.get<window.WindowStage>('windowStage');
      if (!windowStage) {
        console.error('HBOX_WM_NO_STAGE');
        return;
      }
      const main = windowStage.getMainWindowSync();
      AppStorage.setOrCreate<string>('currentAppName', inst.appName);

      const wlSvc = WaylandService.getInstance();
      const useNative: boolean = wlSvc.getUseNativeDecor();

      const subWin: window.Window = await main.createSubWindowWithOptions(
        `app_${inst.instanceId}_${Date.now()}`,
        {
          title: inst.appName,
          decorEnabled: useNative,
          isModal: false,
          maximizeSupported: true
        }
      );
      await subWin.loadContent('pages/AppRunner');

      // 初始尺寸: 优先用 client 已 commit 的 buffer, 否则用 fallback
      const sz: WlBufferSize = wlSvc.getLatestBufferSize(inst.clientId ?? '');
      const scale: number = wlSvc.getUiScale();
      const bufW: number = sz.w > 0 ? sz.w : 800;
      const bufH: number = sz.h > 0 ? sz.h : 600;
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

      const instanceId: string = inst.instanceId;
      subWin.on('windowEvent', (event: window.WindowEventType): void => {
        if (event === window.WindowEventType.WINDOW_DESTROYED) {
          this.onHostWindowDestroyed(instanceId);
        }
      });
      subWin.on('windowSizeChange', (size: window.Size): void => {
        this.handleHostSizeChange(instanceId, size.width, size.height);
      });

      inst.hostWindow = subWin;
      this.notifyChanged();
      await subWin.showWindow();

      // 兜底: 首帧已 commit 但事件早于窗口创建时, 主动调整一次
      if (sz.w > 0 && sz.h > 0 && !this.firstCommitDone.has(instanceId)) {
        this.firstCommitDone.add(instanceId);
        this.applyWindowSize(subWin, sz.w, sz.h);
      }
      console.info(`HBOX_WM_HOST_SHOWN inst=${instanceId} ${totalW}x${totalH}`);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`HBOX_WM_HOST_FAIL code=${err.code} msg=${err.message}`);
    }
  }

  private onHostWindowDestroyed(instanceId: string): void {
    const inst = this.instances.get(instanceId);
    if (!inst) return;
    inst.hostWindow = null;
    // 用户手动关窗 → 视为结束这个实例
    if (inst.clientId) {
      this.clientIndex.delete(inst.clientId);
      inst.clientId = null;
    }
    if (inst.pid > 0) {
      ProcessManagerService.getInstance().terminate(inst.pid);
    }
    this.firstCommitDone.delete(instanceId);
    this.maximizedInsts.delete(instanceId);
    this.savedHostSizes.delete(instanceId);
    if (inst.logWindow === null) {
      this.cleanupInstance(instanceId);
    }
  }

  // =========================================================
  // private helpers
  // =========================================================

  private ensureInstance(
    instanceId: string, appName: string, appId: string, pid: number
  ): AppInstance {
    let inst: AppInstance | undefined = this.instances.get(instanceId);
    if (!inst) {
      inst = {
        instanceId,
        appId,
        appName,
        pid,
        clientId:   null,
        hostWindow: null,
        logWindow:  null,
        createdAt:  Date.now()
      };
      this.instances.set(instanceId, inst);
      if (appId) {
        const list: string[] = this.appIndex.get(appId) ?? [];
        list.push(instanceId);
        this.appIndex.set(appId, list);
      }
      this.notifyChanged();
    } else {
      if (appName && !inst.appName) inst.appName = appName;
      if (appId && !inst.appId) {
        inst.appId = appId;
        const list: string[] = this.appIndex.get(appId) ?? [];
        if (!list.includes(instanceId)) {
          list.push(instanceId);
          this.appIndex.set(appId, list);
        }
      }
      if (pid > 0 && inst.pid <= 0) inst.pid = pid;
    }
    return inst;
  }

  private cleanupInstance(instanceId: string): void {
    const inst = this.instances.get(instanceId);
    if (!inst) return;
    if (inst.clientId) this.clientIndex.delete(inst.clientId);
    if (inst.appId) {
      const list = this.appIndex.get(inst.appId);
      if (list) {
        const filtered = list.filter((id: string): boolean => id !== instanceId);
        if (filtered.length === 0) this.appIndex.delete(inst.appId);
        else this.appIndex.set(inst.appId, filtered);
      }
    }
    this.instances.delete(instanceId);
    this.firstCommitDone.delete(instanceId);
    this.maximizedInsts.delete(instanceId);
    this.savedHostSizes.delete(instanceId);
    this.notifyChanged();
  }

  private getInstanceByClient(clientId: string): AppInstance | null {
    const id = this.clientIndex.get(clientId);
    if (!id) return null;
    return this.instances.get(id) ?? null;
  }

  private pruneExpiredPending(): void {
    const now = Date.now();
    this.pendingQueue = this.pendingQueue.filter(
      (p: PendingLaunch): boolean => (now - p.createdAt) < PENDING_TTL_MS
    );
  }

  private notifyChanged(): void {
    const ids: string[] = [];
    for (const inst of this.instances.values()) {
      if (inst.appId && !ids.includes(inst.appId)) ids.push(inst.appId);
    }
    this.runningAppIds = ids;
    if (this.runningIdsListener) this.runningIdsListener(ids.slice());
    if (this.instancesListener) {
      this.instancesListener(Array.from(this.instances.values()));
    }
  }

  private sendConfigure(clientId: string, hostW: number, hostH: number, maximized: boolean): void {
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
    wlSvc.requestClientResize(clientId, bufW, bufH, maximized);
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
        ).catch((): void => { /* ignore */ });
      } catch (e) { /* ignore */ }
    }).catch((e: BusinessError): void => {
      console.error(`applyWindowSize failed: ${e.code} ${e.message}`);
    });
  }
}