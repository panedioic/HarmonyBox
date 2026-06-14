import wl from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { LibStore } from './LibStore';

export interface CliSubscriber {
  onLine: (line: string) => void;
  onExit: (code: number) => void;
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
  private buffers: Map<number, string[]> = new Map();
  private subscribers: Map<number, CliSubscriber> = new Map();
  private exited: Map<number, number> = new Map();
  private context: common.UIAbilityContext | null = null;

  init(ctx: common.UIAbilityContext): void {
    this.context = ctx;
    if (this.installed) return;
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

  // 通过 box64 启动 x86_64 cli 应用
  launchBox64(
    exeAbsPath: string,
    extraArgs: string[],
    cwd: string,
    extraEnv: string[] = [],
    appDir: string = ''
  ): number {
    if (!this.context) return -1;
    const libPath: string = this.context.applicationInfo.nativeLibraryPath ?? '';
    const argv: string[] = [BOX64_PATH, exeAbsPath];
    for (const a of extraArgs) argv.push(a);

    const env: string[] = [];
    const x64LibDir: string = LibStore.getDir(this.context);
    const ldPaths: string[] = [];
    if (appDir) {
      ldPaths.push(appDir);
      ldPaths.push(`${appDir}/lib`);
    }
    if (x64LibDir) ldPaths.push(x64LibDir);
    if (ldPaths.length > 0) env.push(`BOX64_LD_LIBRARY_PATH=${ldPaths.join(':')}`);

    for (const e of extraEnv) env.push(e);
    return wl.launchCli(BOX64_PATH, argv, libPath, cwd, env);
  }

  // 订阅指定 pid 的输出,返回当前已缓冲的全部行
  subscribe(pid: number, sub: CliSubscriber): string[] {
    this.subscribers.set(pid, sub);
    // 如果进程已退出,主动通知一次
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
    if (pid > 0) {
      try { wl.stopCli(pid); } catch (e) { /* ignore */ }
    }
  }
}