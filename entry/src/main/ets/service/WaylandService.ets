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
    if (this.serverReady) {
      return true;
    }
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
    console.info(`[WL] server ready=${ok}, sock=${this.sockPath}`);
    return ok;
  }

  isServerReady(): boolean {
    return this.serverReady;
  }

  isBox64Ready(): boolean {
    return this.box64Ready;
  }

  getCurrentAppId(): string | null {
    return this.currentAppId;
  }

  // 启动 x86_64 Linux 应用,等待客户端首次提交画面(active)后 resolve
  // 返回值:>0 = pid, -1 = server 未就绪, -2 = 已有应用在跑,
  //        -3 = box64 未就绪, -4 = launch 失败, -5 = 等待 active 超时
  launch(appId: string, exeAbsPath: string, extraArgs: string[]): Promise<number> {
    return new Promise((resolve: (v: number) => void): void => {
      if (!this.serverReady) {
        resolve(-1);
        return;
      }
      if (this.currentAppId) {
        resolve(-2);
        return;
      }
      if (!this.box64Ready) {
        resolve(-3);
        return;
      }

      const libDir: string = LibStore.getDir(this.context!);
      const extraEnv: string[] = [`BOX64_LD_LIBRARY_PATH=${libDir}`];

      const argv: string[] = [this.box64Path, exeAbsPath];
      for (const a of extraArgs) {
        argv.push(a);
      }

      const pid: number = wl.launchClient(
        this.box64Path, argv, this.sockPath, this.libPath, extraEnv
      );
      if (pid <= 0) {
        resolve(-4);
        return;
      }

      this.currentAppId = appId;

      let resolved: boolean = false;
      this.activeWaiter = (ok: boolean): void => {
        if (resolved) return;
        resolved = true;
        resolve(pid);
      };

      setTimeout((): void => {
        if (resolved) return;
        resolved = true;
        this.activeWaiter = null;
        try { wl.stopClient(); } catch (e) { /* ignore */ }
        this.currentAppId = null;
        resolve(-5);
      }, ACTIVE_TIMEOUT_MS);
    });
  }

  // 停止当前客户端,但保留 server,允许下一次启动
  stopCurrent(): void {
    if (this.currentAppId) {
      console.info(`[WL] stop current ${this.currentAppId}`);
      try { wl.stopClient(); } catch (e) { /* ignore */ }
      this.currentAppId = null;
    }
  }

  // 整体停掉,通常只在 ability 销毁时调用
  shutdown(): void {
    if (this.serverReady) {
      try { wl.stopAll(); } catch (e) { /* ignore */ }
      this.serverReady = false;
      this.currentAppId = null;
      this.activeWaiter = null;
    }
  }
}