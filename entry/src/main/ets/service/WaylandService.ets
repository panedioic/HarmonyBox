import wl from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { LibStore } from './LibStore';
import { ToolEnvStore, UiPrefs } from '../model/ToolEnvStore';
import { FontStore } from './FontStore';

export interface WlBufferSize {
  w: number;
  h: number;
}

const ACTIVE_TIMEOUT_MS: number = 15000;

export class WaylandService {
  private static instance: WaylandService | null = null;
  private uiScale: number = 1.0;

  static getInstance(): WaylandService {
    if (!WaylandService.instance) {
      WaylandService.instance = new WaylandService();
    }
    return WaylandService.instance;
  }

  private serverReady: boolean = false;
  private sockPath: string = '';
  private libPath: string = '';
  private box64Path: string = '/data/service/hnp/bin/box64';
  private box64Ready: boolean = false;
  private currentAppId: string | null = null;
  private activeWaiter: ((ok: boolean) => void) | null = null;
  private context: common.UIAbilityContext | null = null;
  private sizeListener: ((w: number, h: number) => void) | null = null;
  private moveListener: (() => void) | null = null;
  private exitListener: (() => void) | null = null;
  private useNativeDecor: boolean = true;
  private maximizeListener: (() => void) | null = null;
  private unmaximizeListener: (() => void) | null = null;
  private resizeListener: ((edges: number) => void) | null = null;

  init(context: common.UIAbilityContext): boolean {
    this.context = context;
    if (this.serverReady) return true;

    this.sockPath = `${context.filesDir}/wl-sock`;
    this.libPath = context.applicationInfo.nativeLibraryPath ?? '';

    const prefs: UiPrefs = ToolEnvStore.loadUiPrefs(context);
    this.uiScale = prefs.scale;
    this.useNativeDecor = prefs.useNativeDecor;

    try {
      this.box64Ready = fs.accessSync(this.box64Path);
    } catch (e) {
      this.box64Ready = false;
    }

    wl.setStateCallback((s: string): void => {
      console.info(`[WL] state=${s}`);
      if (s === 'active' && this.activeWaiter) {
        const w = this.activeWaiter;
        this.activeWaiter = null;
        w(true);
      }
      if (s === 'exited') {
        if (this.exitListener) this.exitListener();
      }
    });

    wl.setSizeCallback((w: number, h: number): void => {
      console.info(`[WL] size=${w}x${h}`);
      if (this.sizeListener) this.sizeListener(w, h);
    });

    wl.setMoveCallback((): void => {
      console.info('[WL] move request');
      if (this.moveListener) this.moveListener();
    });

    wl.setMaximizeCallback((): void => {
      console.info('[WL] maximize request');
      if (this.maximizeListener) this.maximizeListener();
    });

    wl.setUnmaximizeCallback((): void => {
      console.info('[WL] unmaximize request');
      if (this.unmaximizeListener) this.unmaximizeListener();
    });

    wl.setResizeCallback((edges: number): void => {
      console.info(`[WL] resize request edges=0x${edges.toString(16)}`);
      if (this.resizeListener) this.resizeListener(edges);
    });

    const ok: boolean = wl.startWaylandServer(this.sockPath);
    this.serverReady = ok;
    return ok;
  }

  getUiScale(): number {
    return this.uiScale;
  }

  getUseNativeDecor(): boolean {
    return this.useNativeDecor;
  }

  reloadUiPrefs(ctx: common.Context): void {
    const prefs: UiPrefs = ToolEnvStore.loadUiPrefs(ctx);
    this.uiScale = prefs.scale;
    this.useNativeDecor = prefs.useNativeDecor;
  }

  setSizeListener(cb: ((w: number, h: number) => void) | null): void {
    this.sizeListener = cb;
  }

  setMoveListener(cb: (() => void) | null): void {
    this.moveListener = cb;
  }

  setExitListener(cb: (() => void) | null): void {
    this.exitListener = cb;
  }

  setMaximizeListener(cb: (() => void) | null): void {
    this.maximizeListener = cb;
  }

  setUnmaximizeListener(cb: (() => void) | null): void {
    this.unmaximizeListener = cb;
  }

  setResizeListener(cb: ((edges: number) => void) | null): void {
    this.resizeListener = cb;
  }

  getLatestBufferSize(): WlBufferSize {
    try {
      return wl.getLatestSize() as WlBufferSize;
    } catch (e) {
      return { w: 0, h: 0 };
    }
  }

  isServerReady(): boolean { return this.serverReady; }
  isBox64Ready(): boolean { return this.box64Ready; }
  getCurrentAppId(): string | null { return this.currentAppId; }
  getBox64Path(): string { return this.box64Path; }
  getSockPath(): string { return this.sockPath; }
  getLibPath(): string { return this.libPath; }

  // 获取 wayland 客户端需要的环境变量
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

  // 占用 GUI 槽位:成功返回 true,已被占用返回 false
  claimSlot(appId: string): boolean {
    if (!this.serverReady) return false;
    if (this.currentAppId) return false;
    this.currentAppId = appId;
    return true;
  }

  // 释放槽位,并通知 server 重置首帧标记(允许下次 active 触发)
  releaseSlot(appId: string): void {
    if (this.currentAppId === appId) {
      this.currentAppId = null;
      this.activeWaiter = null;
      try { wl.stopClient(); } catch (e) { /* ignore */ }
    }
  }

  // 等待客户端首帧到达
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

  // 旧路径:不带日志,直接 launchClient 等 active
  // 返回 >0 = pid, -1 = server 未就绪, -2 = 槽位已占, -3 = box64 未就绪,
  //       -4 = launch 失败, -5 = 等 active 超时
  async launch(
    appId: string,
    exeAbsPath: string,
    extraArgs: string[],
    extraEnv: string[] = [],
    appDir: string = ''
  ): Promise<number> {
    if (!this.serverReady) return -1;
    if (!this.box64Ready) return -3;
    if (!this.claimSlot(appId)) return -2;

    const argv: string[] = [this.box64Path, exeAbsPath];
    for (const a of extraArgs) argv.push(a);

    const env: string[] = [];
    // 应用目录优先,然后是全局池
    const ldPath: string = this.buildLdPath(appDir);
    if (ldPath) env.push(`BOX64_LD_LIBRARY_PATH=${ldPath}`);
    if (this.context) {
      for (const e of FontStore.buildEnv(this.context)) env.push(e);
    }
    for (const e of extraEnv) env.push(e);

    const pid: number = wl.launchClient(
      this.box64Path, argv, this.sockPath, this.libPath, env
    );
    if (pid <= 0) {
      this.releaseSlot(appId);
      return -4;
    }

    const ok: boolean = await this.waitActive(ACTIVE_TIMEOUT_MS);
    if (!ok) {
      this.releaseSlot(appId);
      return -5;
    }
    return pid;
  }

  private buildLdPath(appDir: string): string {
    const parts: string[] = [];
    if (appDir) {
      parts.push(appDir);
      parts.push(`${appDir}/lib`);
    }
    if (this.context) {
      const x64: string = LibStore.getDir(this.context);
      if (x64) parts.push(x64);
    }
    return parts.join(':');
  }

  // 暴露给 GUI+Log 模式用
  buildAppLdPath(appDir: string): string {
    return this.buildLdPath(appDir);
  }

  // 主动停掉当前客户端
  stopCurrent(): void {
    if (this.currentAppId) {
      try { wl.stopClient(); } catch (e) { /* ignore */ }
      this.currentAppId = null;
      this.activeWaiter = null;
    }
  }

  shutdown(): void {
    if (this.serverReady) {
      try { wl.stopAll(); } catch (e) { /* ignore */ }
      this.serverReady = false;
      this.currentAppId = null;
      this.activeWaiter = null;
    }
  }
}