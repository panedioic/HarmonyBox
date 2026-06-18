import wl from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { LibStore } from './LibStore';
import { FontStore } from './FontStore';
import { WineService } from './WineService';
import { WaylandService } from './WaylandService';

export interface CliSubscriber {
  onLine: (line: string) => void;
  onExit: (code: number) => void;
}

// 启动选项。语义说明:
//   gui=true,  streaming=false : 走 wl.launchClient,占用 GUI 单例槽,有 state="exited" 事件
//   gui=true,  streaming=true  : 走 wl.launchCli,占用 GUI 单例槽,通过 onLine/onExit 拿事件
//   gui=false, streaming=true  : 走 wl.launchCli,无槽,纯流式 CLI 应用
//   gui=false, streaming=false : 不允许,会被拒绝
export interface LaunchOptions {
  exeAbsPath: string;
  extraArgs: string[];
  cwd: string;
  extraEnv: string[];
  appDir: string;          // 用于拼 BOX64_LD_LIBRARY_PATH
  useWine: boolean;
  gui: boolean;
  streaming: boolean;
  appId?: string;          // gui=true 时必填
}

export interface LaunchResult {
  pid: number;             // >0 = 成功
  code: number;            // 0=OK, -1=server未就绪, -2=槽位被占, -3=参数错误,
  // -4=launch 失败 (fork/exec)
  errorMsg: string;
}

const BOX64_PATH: string = '/data/service/hnp/bin/box64';
const MAX_BUFFER_LINES: number = 5000;

export class CliService {
  private static instance: CliService | null = null;

  static getInstance(): CliService {
    if (!CliService.instance) {
      CliService.instance = new CliService();
    }
    return CliService.instance;
  }

  private installed: boolean = false;
  private context: common.UIAbilityContext | null = null;
  private box64Ready: boolean = false;

  // streaming pid 的输出缓冲与订阅者
  private buffers: Map<number, string[]> = new Map();
  private subscribers: Map<number, CliSubscriber> = new Map();
  private exited: Map<number, number> = new Map();

  init(ctx: common.UIAbilityContext): void {
    this.context = ctx;
    if (this.installed) return;

    try {
      this.box64Ready = fs.accessSync(BOX64_PATH);
    } catch (e) {
      this.box64Ready = false;
    }

    wl.setCliCallback((pid: number, ev: string, data: string): void => {
      if (ev === 'out') {
        let buf: string[] | undefined = this.buffers.get(pid);
        if (!buf) {
          buf = [];
          this.buffers.set(pid, buf);
        }
        buf.push(data);
        if (buf.length > MAX_BUFFER_LINES) {
          buf.splice(0, buf.length - MAX_BUFFER_LINES);
        }
        const sub = this.subscribers.get(pid);
        if (sub) sub.onLine(data);
      } else if (ev === 'exit') {
        const code: number = parseInt(data, 10);
        const realCode: number = isNaN(code) ? -1 : code;
        this.exited.set(pid, realCode);
        const sub = this.subscribers.get(pid);
        if (sub) sub.onExit(realCode);
      }
    });

    this.installed = true;
  }

  isBox64Ready(): boolean { return this.box64Ready; }
  getBox64Path(): string { return BOX64_PATH; }

  // =========================================================
  // 唯一启动入口。fork 完成后立即返回,不等 wayland active。
  // GUI 模式下调用方需要自己 await WaylandService.waitActive()。
  // =========================================================
  launchBox64(opts: LaunchOptions): LaunchResult {
    if (!this.context) {
      return { pid: -1, code: -3, errorMsg: 'context 未初始化' };
    }
    if (!opts.gui && !opts.streaming) {
      return { pid: -1, code: -3, errorMsg: 'gui 与 streaming 至少一项为 true' };
    }

    const wlSvc = WaylandService.getInstance();

    // 1) GUI 模式先占槽,失败立即返回
    if (opts.gui) {
      if (!wlSvc.isServerReady()) {
        return { pid: -1, code: -1, errorMsg: 'Wayland 服务未就绪' };
      }
      if (!opts.appId) {
        return { pid: -1, code: -3, errorMsg: 'gui 模式需要 appId' };
      }
      if (!wlSvc.claimSlot(opts.appId)) {
        return { pid: -1, code: -2, errorMsg: '已有 GUI 应用在运行' };
      }
    }

    // 2) 拼 argv / env
    const argv: string[] = this.buildArgv(opts);
    const env: string[] = this.buildEnv(opts);
    const libPath: string = this.context.applicationInfo.nativeLibraryPath ?? '';

    // 3) 选 napi 入口
    let pid: number = -1;
    try {
      if (opts.streaming) {
        pid = wl.launchCli(BOX64_PATH, argv, libPath, opts.cwd, env);
      } else {
        // gui=true && streaming=false: 走单例 client 通道,拿 state 事件
        pid = wl.launchClient(BOX64_PATH, argv, wlSvc.getSockPath(), libPath, env);
      }
    } catch (e) {
      pid = -1;
    }

    if (pid <= 0) {
      if (opts.gui && opts.appId) wlSvc.releaseSlot(opts.appId);
      return { pid: -1, code: -4, errorMsg: '启动失败 (fork/exec)' };
    }

    return { pid, code: 0, errorMsg: '' };
  }

  // =========================================================
  // streaming 输出订阅 (只对 streaming=true 启动的 pid 有意义)
  // =========================================================
  subscribe(pid: number, sub: CliSubscriber): string[] {
    this.subscribers.set(pid, sub);
    const exitCode: number | undefined = this.exited.get(pid);
    if (exitCode !== undefined) {
      setTimeout((): void => { sub.onExit(exitCode); }, 0);
    }
    const buf: string[] | undefined = this.buffers.get(pid);
    return buf ? buf.slice() : [];
  }

  unsubscribe(pid: number): void {
    this.subscribers.delete(pid);
  }

  clear(pid: number): void {
    this.buffers.delete(pid);
    this.exited.delete(pid);
  }

  stop(pid: number): void {
    if (pid <= 0) return;
    try { wl.stopCli(pid); } catch (e) { /* ignore */ }
  }

  // =========================================================
  // private builders
  // =========================================================
  private buildArgv(opts: LaunchOptions): string[] {
    const wineBin: string = (opts.useWine && this.context)
      ? WineService.getBinPath(this.context)
      : '';
    const argv: string[] = opts.useWine
      ? [BOX64_PATH, wineBin, opts.exeAbsPath]
      : [BOX64_PATH, opts.exeAbsPath];
    for (const a of opts.extraArgs) argv.push(a);
    return argv;
  }

  private buildEnv(opts: LaunchOptions): string[] {
    const env: string[] = [];
    const ctx = this.context;
    if (!ctx) {
      for (const e of opts.extraEnv) env.push(e);
      return env;
    }

    // wayland env: 仅在 streaming=true 时由 JS 注入。
    // streaming=false 时 C++ 端 launchClient 已根据 sockPath 自动加,这里不重复。
    if (opts.gui && opts.streaming) {
      for (const e of WaylandService.getInstance().getWaylandEnv()) env.push(e);
    }

    // BOX64_LD_LIBRARY_PATH
    const ldPaths: string[] = [];
    if (opts.appDir) {
      ldPaths.push(opts.appDir);
      ldPaths.push(`${opts.appDir}/lib`);
    }
    const x64LibDir: string = LibStore.getDir(ctx);
    if (x64LibDir) ldPaths.push(x64LibDir);
    if (opts.useWine) {
      for (const p of WineService.buildLdPaths(ctx)) ldPaths.push(p);
    }
    if (ldPaths.length > 0) {
      env.push(`BOX64_LD_LIBRARY_PATH=${ldPaths.join(':')}`);
    }

    // wine
    if (opts.useWine) {
      for (const e of WineService.buildLaunchEnv(ctx)) env.push(e);
    }

    // fonts
    for (const e of FontStore.buildEnv(ctx)) env.push(e);

    // user
    for (const e of opts.extraEnv) env.push(e);

    return env;
  }
}