import wl from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { LibStore } from './LibStore';

const ACTIVE_TIMEOUT_MS: number = 15000;

export class WaylandService {
  private static instance: WaylandService | null = null;

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

  init(context: common.UIAbilityContext): boolean {
    this.context = context;
    if (this.serverReady) return true;

    this.sockPath = `${context.filesDir}/wl-sock`;
    this.libPath = context.applicationInfo.nativeLibraryPath ?? '';

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
    });

    const ok: boolean = wl.startWaylandServer(this.sockPath);
    this.serverReady = ok;
    return ok;
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
    extraEnv: string[] = []
  ): Promise<number> {
    if (!this.serverReady) return -1;
    if (!this.box64Ready) return -3;
    if (!this.claimSlot(appId)) return -2;

    const argv: string[] = [this.box64Path, exeAbsPath];
    for (const a of extraArgs) argv.push(a);

    const libDir: string = this.context ? LibStore.getDir(this.context) : '';
    const env: string[] = [];
    if (libDir) env.push(`BOX64_LD_LIBRARY_PATH=${libDir}`);
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