import { window, display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common, Want } from '@kit.AbilityKit';
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
  // ★ Phase 11:
  hostAbilityContext: common.UIAbilityContext | null;
  logAbilityContext:  common.UIAbilityContext | null;
  hostAttachPending:  boolean;
  logAttachPending:   boolean;
}

const PENDING_TTL_MS: number = 15000;

export type RunningIdsListener = (ids: string[]) => void;
export type InstancesListener  = (list: AppInstance[]) => void;

// ─── 实验字段 (实验后删除) ───
// interface DataRect { left: number; top: number; width: number; height: number };

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

  private ctx: common.Context | null = null;             // ← 通用 Context
  private uiCtx: common.UIAbilityContext | null = null;  // ← 未来 startAbility 用
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

  /*
  // ─── 实验字段 (实验后删除) ───
  private exp_mainHidden: boolean = false;
  private exp_subRectListener: ((data: window.RectChangeOptions) => void) | null = null;
  private exp_latestSubRect: DataRect | null = null;
  private exp_followTimer: number = -1;

  // ─── 实验方法 (实验后删除) ───
  private async experimentHideMainBehind(subWin: window.Window): Promise<void> {
    if (this.exp_mainHidden) {
      console.info('EXP: 已有窗口在跟随, 跳过');
      return;
    }
    const windowStage = AppStorage.get<window.WindowStage>('windowStage');
    if (!windowStage) return;
    const mainWin = windowStage.getMainWindowSync();

    try {
      await mainWin.setWindowLimits({
        minWidth: 1, minHeight: 1, maxWidth: 100, maxHeight: 100
      }, true);
      console.info('EXP: setWindowLimits ok');
    } catch (e) {
      console.warn(`EXP: setWindowLimits fail ${JSON.stringify(e)}`);
    }

    try {
      await mainWin.resizeAsync(1, 1);
      console.info('EXP: main resizeAsync 1x1 ok');
    } catch (e) {
      console.warn(`EXP: resizeAsync fail ${JSON.stringify(e)}`);
    }

    try {
      mainWin.setWindowDecorVisible(false);
      mainWin.setWindowDecorHeight(40);
      mainWin.setWindowTitleButtonVisible(false, false, false);
      console.info('EXP: setWindowDecorVisible false ok');
    } catch (e) {
      console.warn(`EXP: setWindowDecorVisible fail ${JSON.stringify(e)}`);
    }

    try {
      await mainWin.setWindowFocusable(false);
      console.info('EXP: setWindowFocusable false ok');
    } catch (e) {
      console.warn(`EXP: setWindowFocusable fail ${JSON.stringify(e)}`);
    }

    // 立即挪到子窗中心 (保持不变)
    try {
      const r = subWin.getWindowProperties().windowRect;
      this.exp_latestSubRect = { left: r.left, top: r.top, width: r.width, height: r.height };
      await mainWin.moveWindowToAsync(
        r.left + Math.floor(r.width / 2),
        r.top + Math.floor(r.height / 2)
      );
      console.info(`EXP: initial move to ${r.left + r.width / 2},${r.top + r.height / 2}`);
    } catch (e) {
      console.warn(`EXP: initial move fail ${JSON.stringify(e)}`);
    }

    // ★ 监听: 只更新 latestSubRect, 不直接挪
    const listener = (data: window.RectChangeOptions): void => {
      const r = data.rect;
      this.exp_latestSubRect = { left: r.left, top: r.top, width: r.width, height: r.height };
    };
    this.exp_subRectListener = listener;
    subWin.on('windowRectChange', listener);

    // ★ 定时器: 每 100ms 追一次最新位置
    this.exp_followTimer = setInterval((): void => {
      const r = this.exp_latestSubRect;
      if (!r) return;
      const cx: number = r.left + Math.floor(r.width / 2);
      const cy: number = r.top + Math.floor(r.height / 2);
      mainWin.moveWindowToAsync(cx, cy).catch((): void => {  });
    }, 100);

    console.info('EXP: windowRectChange listener + follow timer attached');
    this.exp_mainHidden = true;
  }*/

  // =========================================================
  // lifecycle
  // =========================================================

  initStage(ctx: common.Context): void {
    this.ctx = ctx;
    if (this.installed) return;

    const wlSvc = WaylandService.getInstance();
    // WaylandService.initStage 已由 HBoxAbilityStage 先行调用, 这里不再重复
    // (幂等保护也在 initStage 内部)

    wlSvc.setClientConnectListener((cid: string, instanceId: string): void => {
      this.handleClientConnect(cid, instanceId);
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

  initUI(ctx: common.UIAbilityContext): void {
    this.uiCtx = ctx;
  }

  /** @deprecated 使用 initStage / initUI 替代 */
  init(ctx: common.UIAbilityContext): void {
    this.initStage(ctx);
    this.initUI(ctx);
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

  /** @deprecated 迁移到 CliRunnerAbility 后此路径废弃, 保留用作回退参考 */
  async createLogWindow_deprecated(instanceId: string, appName: string, pid: number): Promise<void> {
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

      // per-window LocalStorage
      const storage: LocalStorage = new LocalStorage();
      storage.setOrCreate<string>('instanceId', instanceId);
      storage.setOrCreate<string>('appName',    appName);
      storage.setOrCreate<number>('cliPid',     pid);

      await subWin.loadContent('pages/CliRunner', storage);

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

  /** 创建日志窗口: 通过 startAbility 拉起 CliRunnerAbility */
  async createLogWindow(instanceId: string, appName: string, pid: number): Promise<void> {
    const inst = this.ensureInstance(instanceId, appName, '', pid);
    if (inst.logAttachPending || inst.logAbilityContext) {
      console.info(`[WMS] createLogWindow skip (pending or attached) inst=${instanceId}`);
      return;
    }
    const uiCtx = this.uiCtx;
    if (!uiCtx) {
      console.error('[WMS] createLogWindow: uiCtx not ready');
      ProcessManagerService.getInstance().terminate(pid);
      return;
    }

    inst.logAttachPending = true;
    const want: Want = {
      bundleName: uiCtx.abilityInfo.bundleName,
      abilityName: 'CliRunnerAbility',
      parameters: {
        instanceId: instanceId,
        appName:    appName,
        appId:      inst.appId,
        pid:        pid
      }
    };
    try {
      await uiCtx.startAbility(want);
      console.info(`[WMS] CliRunnerAbility startAbility ok inst=${instanceId}`);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[WMS] CliRunnerAbility startAbility failed: ${err.code} ${err.message}`);
      inst.logAttachPending = false;
    }
  }

  // =========================================================
  // API: 外部销毁 / 恢复
  // =========================================================

  /** 主动销毁一个实例 (关窗口 + 停进程 + 清数据) */
  destroyInstance(instanceId: string): void {
    const inst: AppInstance | undefined = this.instances.get(instanceId);
    if (!inst) return;

    // GUI: 优先用 terminateSelf 关闭整个 Ability
    if (inst.hostAbilityContext) {
      inst.hostAbilityContext.terminateSelf().catch((): void => { /* ignore */ });
      inst.hostAbilityContext = null;
      inst.hostWindow = null;
    } else if (inst.hostWindow) {
      inst.hostWindow.destroyWindow().catch((): void => { /* ignore */ });
      inst.hostWindow = null;
    }

    // LOG: 同上
    if (inst.logAbilityContext) {
      inst.logAbilityContext.terminateSelf().catch((): void => { /* ignore */ });
      inst.logAbilityContext = null;
      inst.logWindow = null;
    } else if (inst.logWindow) {
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

  private handleClientConnect(clientId: string, recvInstanceId: string): void {
    this.pruneExpiredPending();

    let pending: PendingLaunch | undefined;
    let matchType: string = 'AUTO';

    // 1. 优先: instanceId 精确匹配
    if (recvInstanceId) {
      const idx: number = this.pendingQueue.findIndex(
        (p: PendingLaunch): boolean => p.instanceId === recvInstanceId
      );
      if (idx >= 0) {
        pending = this.pendingQueue.splice(idx, 1)[0];
        matchType = 'EXACT';
      }
    }

    // 2. 兜底: FIFO 头部
    if (!pending && this.pendingQueue.length > 0) {
      pending = this.pendingQueue.shift();
      matchType = recvInstanceId ? 'FIFO_FALLBACK' : 'FIFO';
    }

    let instanceId: string;
    let appName: string;
    let appId: string;

    if (pending) {
      instanceId = pending.instanceId;
      appName    = pending.appName;
      appId      = pending.appId;
    } else {
      // shell 里手动起的 wine, 无预登记
      // 若 client 带了 instanceId 但队列没匹配, 用它做实例名; 否则生成 auto-N
      instanceId = recvInstanceId || `auto-${++this.autoSeq}`;
      const stashed: string | undefined = AppStorage.get<string>('currentAppName');
      appName = (stashed && stashed.length > 0) ? stashed : 'External App';
      appId   = '';
    }

    console.info(
      `HBOX_WM_CLIENT_MATCH_${matchType} inst=${instanceId} `
        + `cid=${clientId} recvInst=${recvInstanceId || '(none)'}`
    );

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

    // 关闭 GUI 窗口 (Ability 或 SubWindow)
    if (inst.hostAbilityContext) {
      inst.hostAbilityContext.terminateSelf().catch((): void => { /* ignore */ });
      inst.hostAbilityContext = null;
      inst.hostWindow = null;
    } else if (inst.hostWindow) {
      inst.hostWindow.destroyWindow().catch((): void => { /* ignore */ });
      inst.hostWindow = null;
    }
    this.clientIndex.delete(clientId);
    inst.clientId = null;

    if (inst.logWindow === null && inst.logAbilityContext === null) {   // ★
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
      WaylandService.getInstance().fireHostResizeBegin(clientId, edges);   // ← 加 clientId
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

  /** @deprecated 迁移到 AppRunnerAbility 后此路径废弃, 保留用作回退参考 */
  private async createHostWindow_deprecated(inst: AppInstance): Promise<void> {
    try {
      const windowStage = AppStorage.get<window.WindowStage>('windowStage');
      if (!windowStage) {
        console.error('HBOX_WM_NO_STAGE');
        return;
      }
      const main = windowStage.getMainWindowSync();

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

      // 每窗口独立 LocalStorage
      const storage: LocalStorage = new LocalStorage();
      storage.setOrCreate<string>('instanceId', inst.instanceId);
      storage.setOrCreate<string>('appName',    inst.appName);
      storage.setOrCreate<string>('appId',      inst.appId);
      storage.setOrCreate<string>('clientId',   inst.clientId ?? '');

      await subWin.loadContent('pages/AppRunner', storage);

      // 剩下的尺寸/位置/事件挂载保持不变
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

      // ─── 实验: 主窗躲子窗后面 (仅第一个应用) ───
      // this.experimentHideMainBehind(subWin).catch((e: BusinessError): void => {
      //   console.error(`EXP failed: ${e.code} ${e.message}`);
      // });

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

  // =========================================================
  // host window creation (通过 startAbility 拉起 AppRunnerAbility)
  // =========================================================

  private async createHostWindow(inst: AppInstance): Promise<void> {
    if (inst.hostAttachPending || inst.hostAbilityContext) {
      console.info(`[WMS] createHostWindow skip (pending or attached) inst=${inst.instanceId}`);
      return;
    }
    const uiCtx = this.uiCtx;
    if (!uiCtx) {
      console.error('[WMS] createHostWindow: uiCtx not ready');
      return;
    }

    inst.hostAttachPending = true;
    const want: Want = {
      bundleName: uiCtx.abilityInfo.bundleName,
      abilityName: 'AppRunnerAbility',
      parameters: {
        instanceId: inst.instanceId,
        appName:    inst.appName,
        appId:      inst.appId,
        clientId:   inst.clientId ?? ''
      }
    };
    try {
      await uiCtx.startAbility(want);
      console.info(`[WMS] AppRunnerAbility startAbility ok inst=${inst.instanceId}`);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[WMS] AppRunnerAbility startAbility failed: ${err.code} ${err.message}`);
      inst.hostAttachPending = false;
    }
  }

  private onHostWindowDestroyed(instanceId: string): void {
    const inst = this.instances.get(instanceId);
    if (!inst) return;
    inst.hostWindow = null;
    inst.hostAbilityContext = null;   // ★ 新增
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
    if (inst.logWindow === null && inst.logAbilityContext === null) {   // ★ 补齐 Ability 判断
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
        clientId:            null,
        hostWindow:          null,
        logWindow:           null,
        createdAt:           Date.now(),
        hostAbilityContext:  null,
        logAbilityContext:   null,
        hostAttachPending:   false,
        logAttachPending:    false
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

  // =========================================================
  // Ability 挂载 (Phase 11 Step 2: stub, 完整实现在 Step 4)
  // =========================================================

  attachAppRunnerAbility(
    instanceId: string,
    ctx: common.UIAbilityContext,
    stage: window.WindowStage
  ): void {
    console.info(`[WMS] attachAppRunnerAbility inst=${instanceId}`);
    const inst = this.instances.get(instanceId);
    if (!inst) {
      console.error(`[WMS] attach: instance ${instanceId} not found, closing ability`);
      ctx.terminateSelf().catch((): void => { /* ignore */ });
      return;
    }

    let mainWin: window.Window;
    try {
      mainWin = stage.getMainWindowSync();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[WMS] getMainWindowSync failed: ${err.code} ${err.message}`);
      return;
    }

    inst.hostAbilityContext = ctx;
    inst.hostWindow = mainWin;
    inst.hostAttachPending = false;

    this.setupHostWindow(inst, mainWin);
    this.notifyChanged();
  }

  detachAppRunnerAbility(instanceId: string): void {
    console.info(`[WMS] detachAppRunnerAbility inst=${instanceId}`);
    const inst = this.instances.get(instanceId);
    if (!inst) return;
    inst.hostAbilityContext = null;
    // hostWindow 由 onHostWindowDestroyed 清空 (windowEvent WINDOW_DESTROYED 会触发)
    // 但 Ability 层的销毁不一定伴随 windowEvent, 显式调一次保底
    this.onHostWindowDestroyed(instanceId);
  }

  attachCliRunnerAbility(
    instanceId: string,
    ctx: common.UIAbilityContext,
    stage: window.WindowStage
  ): void {
    console.info(`[WMS] attachCliRunnerAbility inst=${instanceId}`);
    const inst = this.instances.get(instanceId);
    if (!inst) {
      console.error(`[WMS] attachCli: instance ${instanceId} not found, closing ability`);
      ctx.terminateSelf().catch((): void => { /* ignore */ });
      return;
    }

    let mainWin: window.Window;
    try {
      mainWin = stage.getMainWindowSync();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[WMS] getMainWindowSync (log) failed: ${err.code} ${err.message}`);
      return;
    }

    inst.logAbilityContext = ctx;
    inst.logWindow = mainWin;
    inst.logAttachPending = false;

    this.setupLogWindow(inst, mainWin);
    this.notifyChanged();
  }

  detachCliRunnerAbility(instanceId: string): void {
    console.info(`[WMS] detachCliRunnerAbility inst=${instanceId}`);
    const inst = this.instances.get(instanceId);
    if (!inst) return;
    inst.logAbilityContext = null;
    inst.logWindow = null;
    // 用户关闭日志窗 → terminate 进程 (与原 createLogWindow 语义一致)
    if (inst.pid > 0) {
      ProcessManagerService.getInstance().terminate(inst.pid);
    }
    // 只有 GUI 也没了才清整个 instance
    if (inst.hostWindow === null && inst.hostAbilityContext === null) {
      this.cleanupInstance(instanceId);
    }
  }

  // =========================================================
  // setup: Ability 侧回调时把窗口挂上, 尺寸/位置/事件全在这里
  // =========================================================

  private setupHostWindow(inst: AppInstance, win: window.Window): void {
    const wlSvc = WaylandService.getInstance();
    const useNative: boolean = wlSvc.getUseNativeDecor();

    // 装饰栏
    try { win.setWindowDecorVisible(useNative); } catch (e) { /* ignore */ }
    try { win.setWindowBackgroundColor('#FF000000'); } catch (e) { /* ignore */ }
    // 主窗口不支持 setWindowCornerRadius, 通过 AppRunner 页面的 borderRadius 实现视觉圆角

    // 尺寸: 基于 wayland buffer 或缺省 800x600
    const sz: WlBufferSize = wlSvc.getLatestBufferSize(inst.clientId ?? '');
    const scale: number = wlSvc.getUiScale();
    const bufW: number = sz.w > 0 ? sz.w : 800;
    const bufH: number = sz.h > 0 ? sz.h : 600;
    const totalW: number = Math.max(1, Math.round(bufW * scale));
    const totalH: number = Math.max(1, Math.round(bufH * scale));

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
      console.warn(`[WMS] setupHostWindow resize failed: ${e.code} ${e.message}`);
    });

    const instanceId: string = inst.instanceId;
    win.on('windowEvent', (event: window.WindowEventType): void => {
      if (event === window.WindowEventType.WINDOW_DESTROYED) {
        this.onHostWindowDestroyed(instanceId);
      }
    });
    win.on('windowSizeChange', (size: window.Size): void => {
      this.handleHostSizeChange(instanceId, size.width, size.height);
    });

    if (sz.w > 0 && sz.h > 0 && !this.firstCommitDone.has(instanceId)) {
      this.firstCommitDone.add(instanceId);
      this.applyWindowSize(win, sz.w, sz.h);
    }
    console.info(`HBOX_WM_HOST_SHOWN inst=${instanceId} ${totalW}x${totalH}`);
  }

  private setupLogWindow(inst: AppInstance, win: window.Window): void {
    try { win.setWindowBackgroundColor('#FF0E0E0E'); } catch (e) { /* ignore */ }

    const w: number = 1440;
    const h: number = 960;
    const attachedToGui: boolean = inst.hostAbilityContext !== null || inst.hostWindow !== null;
    const offset: number = attachedToGui ? 200 : 0;

    win.resize(w, h).then((): void => {
      try {
        const prop = win.getWindowProperties();
        const di = display.getDisplayByIdSync(prop.displayId);
        win.moveWindowToGlobal(
          Math.round((di.availableWidth - w) / 2 - offset),
          Math.round((di.availableHeight - h) / 2 + offset / 2),
          { displayId: prop.displayId }
        ).catch((): void => { /* ignore */ });
      } catch (e) { /* ignore */ }
    }).catch((e: BusinessError): void => {
      console.warn(`[WMS] setupLogWindow resize failed: ${e.code} ${e.message}`);
    });

    const instanceId: string = inst.instanceId;
    const pid: number = inst.pid;
    win.on('windowEvent', (event: window.WindowEventType): void => {
      if (event === window.WindowEventType.WINDOW_DESTROYED) {
        const cur = this.instances.get(instanceId);
        if (cur) cur.logWindow = null;
        if (pid > 0) ProcessManagerService.getInstance().terminate(pid);
        if (cur && cur.hostWindow === null && cur.hostAbilityContext === null) {
          this.cleanupInstance(instanceId);
        }
      }
    });

    console.info(`HBOX_WM_LOG_SHOWN inst=${instanceId}`);
  }
}