import wl from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { LibStore } from './LibStore';
import { FontStore } from './FontStore';
import { WineService } from './WineService';
import { WaylandService } from './WaylandService';
import { Box64Env, ToolEnvStore } from '../model/ToolEnvStore';

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

    // 不再需要 wl.setCliCallback —— 用每次 runBox64 调用时的 per-call 回调取代
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
    // CliService.ets - launchBox64 方法开头
    if (!wl.ensureBox64TmpDir()) {
      console.error('HBOX_CLI ensureBox64TmpDir failed');
      // 不阻断启动，因为 C++ 侧还会在子进程中再检查一次
    }
    // 启动 Control Socket，用于创建子进程。若已经创建过则会略过。
    // socket 暂时写死
    wl.startProcMgr('/data/storage/el2/base/haps/entry/files/.procmgr.sock');

    const wlSvc = WaylandService.getInstance();

    // 1. GUI 模式先占槽,失败立即返回
    if (opts.gui) {
      if (!wlSvc.isServerReady()) {
        return { pid: -1, code: -1, errorMsg: 'Wayland 服务未就绪' };
      }
      if (!opts.appId) {
        return { pid: -1, code: -3, errorMsg: 'gui 模式需要 appId' };
      }
      // if (!wlSvc.claimSlot(opts.appId)) {
      //   return { pid: -1, code: -2, errorMsg: '已有 GUI 应用在运行' };
      // }
    }

    // 2. 拼 argv / env
    const argv: string[] = this.buildArgv(opts);
    const env: string[] = this.buildEnv(opts);

    let pid: number = -1;
    try {
      // gui=true && streaming=false: 不再走 launchClient,统一用 runBox64,
      // 自己当 subscriber 把 exit 信号路由到 WaylandService
      const cb = (event: string, data: string): void => {
        this.handleStreamEvent(pid, event, data);
      };
      pid = wl.runBox64(opts.exeAbsPath, argv, env, opts.cwd, cb);
      if (pid > 0 && opts.gui && opts.appId) {
        const appId = opts.appId;
        this.subscribe(pid, {
          onLine: (): void => { /* B 模式丢弃日志 */ },
          onExit: (): void => {
            this.unsubscribe(pid);
            this.clear(pid);
            // WaylandService.getInstance().fireGuiExit(appId);
          }
        });
      }
    } catch (e) {
      pid = -1;
    }

    if (pid <= 0) {
      // if (opts.gui && opts.appId) wlSvc.releaseSlot(opts.appId);
      return { pid: -1, code: -4, errorMsg: '启动失败' };
    }

    return { pid, code: 0, errorMsg: '' };
  }

  // 把单次回调事件写进 buffer/subscribers map,供 CliRunner 订阅
  private handleStreamEvent(pid: number, event: string, data: string): void {
    if (event === 'out') {
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
    } else if (event === 'exit') {
      const code: number = parseInt(data, 10);
      const realCode: number = isNaN(code) ? -1 : code;
      this.exited.set(pid, realCode);
      const sub = this.subscribers.get(pid);
      if (sub) sub.onExit(realCode);
    }
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
    // 用新的 terminate (SIGTERM + 800ms 后 SIGKILL),比原 stopCli 多一层兜底
    try { wl.terminate(pid); } catch (e) { /* ignore */ }
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

    // 1) wayland env: streaming=true 时由 JS 注入,
    //    streaming=false 时 cpp 侧的 launchClient 已根据 sockPath 自动加,这里不重复
    if (opts.gui && opts.streaming) {
      for (const e of WaylandService.getInstance().getWaylandEnv()) env.push(e);
    }

    // 2) 设置页全局 box64 默认值: BOX64_LOG / BOX64_NOBANNER / BOX64_DYNAREC
    //    放在 BOX64_LD_LIBRARY_PATH 之前, 便于 customEnv / per-app 覆盖
    const box64Env: Box64Env = ToolEnvStore.loadBox64(ctx);
    if (box64Env.BOX64_LOG.length > 0)      env.push(`BOX64_LOG=${box64Env.BOX64_LOG}`);
    if (box64Env.BOX64_NOBANNER.length > 0) env.push(`BOX64_NOBANNER=${box64Env.BOX64_NOBANNER}`);
    if (box64Env.BOX64_DYNAREC.length > 0)  env.push(`BOX64_DYNAREC=${box64Env.BOX64_DYNAREC}`);

    // 3) BOX64_LD_LIBRARY_PATH: 自动路径 + 设置页追加路径(合并策略)
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
    if (box64Env.BOX64_LD_LIBRARY_PATH.length > 0) {
      const expanded: string =
        CliService.expandPlaceholders(box64Env.BOX64_LD_LIBRARY_PATH, ctx);
      const extras: string[] = expanded
        .split(':')
        .map((s: string): string => s.trim())
        .filter((s: string): boolean => s.length > 0);
      for (const p of extras) ldPaths.push(p);
    }
    if (ldPaths.length > 0) {
      env.push(`BOX64_LD_LIBRARY_PATH=${ldPaths.join(':')}`);
    }

    // 4) wine
    if (opts.useWine) {
      for (const e of WineService.buildLaunchEnv(ctx)) env.push(e);
    }

    // 5) fontconfig
    for (const e of FontStore.buildEnv(ctx)) env.push(e);

    // 6) 设置页 customEnv: 多行 KEY=VALUE
    //    放在常规 env 之后, 用户可以在这里完全覆盖 BOX64_LD_LIBRARY_PATH 等
    for (const e of CliService.parseGlobalEnvLines(box64Env.customEnv, ctx)) {
      env.push(e);
    }

    // 7) per-app extraEnv: 最高优先级
    for (const e of opts.extraEnv) env.push(e);

    return env;
  }

  // ============ 设置页全局 env 解析工具 ============

  // 把 ${X64_LIBS} / ${FILES_DIR} 展开为沙箱实际路径
  // 注意: ${APP_DIR} 是 per-app 上下文, 不在这里展开 —— 让用户的 envVars 自己处理
  private static expandPlaceholders(text: string, ctx: common.Context): string {
    const x64Libs: string = LibStore.getDir(ctx);
    const filesDir: string = ctx.filesDir;
    return text
      .replace(/\$\{X64_LIBS\}/g, x64Libs)
      .replace(/\$\{FILES_DIR\}/g, filesDir);
  }

  // 解析 customEnv 多行文本: 用换行或 ; 分隔, 跳过空行 / # 注释 / 不含 = 的行
  private static parseGlobalEnvLines(text: string, ctx: common.Context): string[] {
    if (!text) return [];
    const out: string[] = [];
    const parts: string[] = text.split(/[;\n\r]+/);
    for (const raw of parts) {
      const line: string = raw.trim();
      if (line.length === 0) continue;
      if (line.startsWith('#')) continue;
      if (!line.includes('=')) continue;
      out.push(CliService.expandPlaceholders(line, ctx));
    }
    return out;
  }
}