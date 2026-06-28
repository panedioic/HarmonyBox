import wl from 'libentry.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Theme } from '../common/Theme';
import { WineService } from '../service/WineService';
import { LibStore } from '../service/LibStore';
import { WaylandService } from '../service/WaylandService';
import { ResourceService, ResourceProbe } from '../service/ResourceService';

interface GeneratedTypeLiteralInterface_1 {
  v: boolean;
}

@Component
export struct DebugPage {
  @State output: string = '';
  @State running: boolean = false;
  @State copyHint: boolean = false;
  @State wineserverPid: number = 0;
  @State sockStarted: boolean = false;
  private scroller: Scroller = new Scroller();
  private readonly procSockPath: string =
    '/data/storage/el2/base/haps/entry/files/.procmgr.sock';

  private append(s: string): void {
    this.output = this.output + s + '\n';
    setTimeout((): void => { this.scroller.scrollEdge(Edge.Bottom); }, 0);
  }

  private clear(): void { this.output = ''; }

  private existsLabel(p: string): string {
    try { return fs.accessSync(p) ? 'YES' : 'NO '; } catch (e) { return 'NO '; }
  }

  private readPart(path: string, head: number, tail: number): string {
    try {
      if (!fs.accessSync(path)) return '(not exist)';
      const text: string = fs.readTextSync(path);
      const lines: string[] = text.split('\n');
      if (head > 0) return lines.slice(0, head).join('\n');
      if (tail > 0) return lines.slice(-tail).join('\n');
      return text;
    } catch (e) {
      return `(read error: ${(e as Error).message})`;
    }
  }

  // 使用 libbox64.so 执行命令并捕获输出
  private async runBox64Capture(args: string[], env: string[], cwd: string): Promise<string> {
    return new Promise((resolve) => {
      let out: string = '';
      const cb = (event: string, data: string): void => {
        if (event === 'out') {
          out += data + '\n';
        } else if (event === 'exit') {
          const code = parseInt(data, 10);
          resolve(`[exit=${code}]\n${out.trim()}`);
        }
      };
      const pid = wl.runBox64('box64', args, env, cwd, cb);
      if (pid <= 0) {
        resolve(`[run error] pid=${pid}`);
      }
    });
  }

  private buildEnv(logLevel: string): string[] {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const ldPaths: string[] = WineService.buildLdPaths(ctx);
    const x64: string = LibStore.getDir(ctx);
    if (x64) ldPaths.push(x64);
    const env: string[] = [
      `BOX64_LD_LIBRARY_PATH=${ldPaths.join(':')}`,
      `BOX64_LOG=${logLevel}`,
      `BOX64_NOBANNER=0`,
      // `BOX64_REMAP_TRACE=0`
    ];
    for (const e of WineService.buildLaunchEnv(ctx)) env.push(e);
    return env;
  }

  // ===== Sections =====
  private async secEnv(): Promise<void> {
    this.append('===== ENV =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const libPath: string = ctx.applicationInfo?.nativeLibraryPath ?? '';
    this.append(`filesDir       = ${ctx.filesDir}`);
    this.append(`nativeLibPath  = ${libPath}`);
    this.append(`libbox64.so    = ${this.existsLabel(`${libPath}/libbox64.so`)}`);

    const sockPath = WaylandService.getInstance().getSockPath();
    this.append(`wl-sock        = ${this.existsLabel(sockPath)} (${sockPath})`);

    const wineRoot: string = WineService.getRootDir(ctx);
    this.append(`wineRoot       = ${wineRoot}`);
    this.append(`wine bin       = ${this.existsLabel(WineService.getBinPath(ctx))}`);
    this.append(`wineserver     = ${this.existsLabel(`${wineRoot}/bin/wineserver`)}`);
    this.append(`prefix         = ${WineService.getPrefixDir(ctx)}`);

    this.append('\n-- /proc/self/status (head 12) --');
    this.append(this.readPart('/proc/self/status', 12, 0));
    this.append('\n-- /proc/self/attr/current --');
    this.append(this.readPart('/proc/self/attr/current', 0, 0));
    this.append('\n-- /proc/sys/vm/mmap_min_addr --');
    this.append(this.readPart('/proc/sys/vm/mmap_min_addr', 0, 0));
    this.append('\n-- /proc/self/maps (tail 25) --');
    this.append(this.readPart('/proc/self/maps', 0, 25));
  }

  private async secWineFiles(): Promise<void> {
    this.append('===== WINE FILES =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const root: string = WineService.getRootDir(ctx);
    const checks: string[] = [
      `${root}/bin/wine`,
      `${root}/bin/wineserver`,
      `${root}/bin/wineboot`,
      `${root}/lib/x86_64/libgcc_s.so.1`,
      `${root}/lib/wine/x86_64-unix/ntdll.so`,
      `${root}/lib/wine/x86_64-unix/winewayland.drv.so`,
      `${root}/lib/wine/x86_64-windows/ntdll.dll`,
      `${root}/lib/wine/x86_64-windows/kernel32.dll`,
      `${root}/share/wine/wine.inf`
    ];
    for (const p of checks) this.append(`${this.existsLabel(p)} ${p}`);

    const xunix: string = `${root}/lib/wine/x86_64-unix`;
    this.append(`\n-- ls ${xunix} --`);
    try {
      if (fs.accessSync(xunix)) {
        const list: string[] = fs.listFileSync(xunix);
        this.append(`(${list.length} entries)`);
        const showN: number = Math.min(40, list.length);
        for (let i = 0; i < showN; i++) this.append(`  ${list[i]}`);
        if (list.length > 40) this.append(`  ...(+${list.length - 40} more)`);
      } else {
        this.append('(not exist)');
      }
    } catch (e) {
      this.append(`(error: ${(e as Error).message})`);
    }
  }

  private async secWayland(): Promise<void> {
    this.append('===== WAYLAND =====');
    const wlSvc = WaylandService.getInstance();
    this.append(`server ready   = ${wlSvc.isServerReady()}`);
    this.append(`sock path      = ${wlSvc.getSockPath()}`);
    this.append(`current appId  = ${wlSvc.getCurrentAppId() ?? '(none)'}`);
    const sz = wlSvc.getLatestBufferSize();
    this.append(`latest buffer  = ${sz.w}x${sz.h}`);
    const env = wlSvc.getWaylandEnv();
    this.append('wayland env:');
    for (const e of env) this.append(`  ${e}`);
  }

  private async secResources(): Promise<void> {
    this.append('===== RESOURCES =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const names: string[] = ['weston', 'xkb'];
    for (const name of names) {
      const probe: ResourceProbe = ResourceService.probe(ctx, name);
      this.append(`${name.padEnd(10)} = ${probe.installed ? 'YES' : 'NO '} ${probe.path}`);
    }
    const wineStatus = WineService.probe(ctx);
    this.append(`wine       = ${wineStatus.installed ? 'YES' : 'NO '} ${wineStatus.rootDir}`);
  }

  private async secBox64(): Promise<void> {
    this.append('===== box64 --version =====');
    this.append(await this.runBox64Capture(['box64', '--version'], [], ''));
  }

  private async secWineVersion(): Promise<void> {
    this.append('===== box64 wine --version =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const wineBin: string = WineService.getBinPath(ctx);
    this.append(await this.runBox64Capture(
      ['box64', wineBin, '--version'], this.buildEnv('1'), ''
    ));
  }

  private async secWineserver(): Promise<void> {
    this.append('===== box64 wineserver --version =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const wineserver: string = `${WineService.getRootDir(ctx)}/bin/wineserver`;
    this.append(await this.runBox64Capture(
      ['box64', wineserver, '--version'], this.buildEnv('1'), ''
    ));
  }

  private async secPrefix(): Promise<void> {
    this.append('===== PREFIX =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const prefix: string = WineService.getPrefixDir(ctx);
    this.append(`prefix = ${prefix}`);
    try {
      const list: string[] = fs.listFileSync(prefix);
      this.append(`top entries: ${list.length}`);
      for (const e of list) this.append(`  ${e}`);
    } catch (e) {
      this.append(`(list err: ${(e as Error).message})`);
    }
    this.append('');
    this.append(`system.reg   = ${this.existsLabel(`${prefix}/system.reg`)}`);
    this.append(`drive_c      = ${this.existsLabel(`${prefix}/drive_c`)}`);
    this.append(`ntdll.dll    = ${this.existsLabel(`${prefix}/drive_c/windows/system32/ntdll.dll`)}`);
    this.append(`kernel32.dll = ${this.existsLabel(`${prefix}/drive_c/windows/system32/kernel32.dll`)}`);
  }

  private async secSetupPrefix(force: boolean = false): Promise<void> {
    this.append(force ? '===== RESET + SETUP PREFIX =====' : '===== SETUP PREFIX (NAPI) =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const prefix: string = WineService.getPrefixDir(ctx);
    const wineRoot: string = WineService.getRootDir(ctx);

    this.append(`prefix    = ${prefix}`);
    this.append(`wineRoot  = ${wineRoot}`);
    this.append('');

    if (force) {
      const marker: string = `${prefix}/.box64_setup_done`;
      try {
        if (fs.accessSync(marker)) {
          fs.unlinkSync(marker);
          this.append(`removed marker: ${marker}`);
        }
      } catch (e) {
        this.append(`unlink err: ${(e as Error).message}`);
      }
    }

    // 探测源目录布局, 帮排查 .dll vs .dll.so
    const sys32Src: string = `${wineRoot}/lib/wine/x86_64-windows`;
    const wow64Src: string = `${wineRoot}/lib/wine/i386-windows`;
    this.append(`src sys32  = ${this.existsLabel(sys32Src)} ${sys32Src}`);
    this.append(`src wow64  = ${this.existsLabel(wow64Src)} ${wow64Src}`);

    if (fs.accessSync(sys32Src)) {
      try {
        const list: string[] = fs.listFileSync(sys32Src);
        this.append(`sys32 src has ${list.length} entries, sample:`);
        const sample: string[] = list.filter((n: string): boolean =>
        n.toLowerCase().startsWith('kernel32') ||
          n.toLowerCase().startsWith('ntdll') ||
          n.toLowerCase().startsWith('user32')
        );
        for (const s of sample) this.append(`  ${s}`);
      } catch (e) {
        this.append(`(list err: ${(e as Error).message})`);
      }
    }

    // 调 NAPI
    this.append('');
    this.append('calling wl.setupWinePrefix(...)');
    const startMs: number = Date.now();
    let ok: boolean = false;
    let errMsg: string = '';
    try {
      ok = wl.setupWinePrefix(prefix, wineRoot);
    } catch (e) {
      errMsg = (e as Error).message;
    }
    const cost: number = (Date.now() - startMs) / 1000;
    this.append(`result    = ${ok ? 'OK' : 'FAIL'} (${cost.toFixed(2)}s)`);
    if (errMsg.length > 0) this.append(`error     = ${errMsg}`);

    // 结果验证
    this.append('');
    this.append('-- after setup --');
    const marker: string  = `${prefix}/.box64_setup_done`;
    const driveC: string  = `${prefix}/drive_c`;
    const kernel: string  = `${driveC}/windows/system32/kernel32.dll`;
    const ntdll: string   = `${driveC}/windows/system32/ntdll.dll`;
    this.append(`marker         = ${this.existsLabel(marker)} ${marker}`);
    this.append(`drive_c        = ${this.existsLabel(driveC)}`);
    this.append(`kernel32.dll   = ${this.existsLabel(kernel)} ${kernel}`);
    this.append(`ntdll.dll      = ${this.existsLabel(ntdll)}`);

    // 列一下 system32 实际有多少文件
    const sys32Dst: string = `${driveC}/windows/system32`;
    try {
      if (fs.accessSync(sys32Dst)) {
        const list: string[] = fs.listFileSync(sys32Dst);
        this.append(`system32 dst entries = ${list.length}`);
      }
    } catch (e) {
      this.append(`(list sys32 err: ${(e as Error).message})`);
    }
  }

  // 强制重置标记 + 再跑一次, 便于反复测试
  private async secResetAndSetup(): Promise<void> {
    this.append('===== RESET + SETUP PREFIX =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const prefix: string = WineService.getPrefixDir(ctx);
    const marker: string = `${prefix}/.box64_setup_done`;
    try {
      if (fs.accessSync(marker)) {
        fs.unlinkSync(marker);
        this.append(`removed marker: ${marker}`);
      } else {
        this.append('marker not present');
      }
    } catch (e) {
      this.append(`unlink err: ${(e as Error).message}`);
    }
    this.append('');
    await this.secSetupPrefix();
  }

  // 直接用 ArkTS fs API 读 box64-tmp 目录, 看 wineserver 创建了什么
  private async secBox64Tmp(): Promise<void> {
    this.append('===== /tmp (box64-tmp) =====');
    const tmp: string = '/data/storage/el2/base/cache/box64-tmp';
    try {
      if (!fs.accessSync(tmp)) {
        this.append('(not exist)');
        return;
      }
      const list: string[] = fs.listFileSync(tmp);
      this.append(`top entries: ${list.length}`);
      for (const e of list) {
        const p: string = `${tmp}/${e}`;
        try {
          const st = fs.statSync(p);
          this.append(`  ${st.isDirectory() ? 'D' : 'F'} ${e} (${st.size}b)`);
        } catch (er) {
          this.append(`  ? ${e}`);
        }
      }
      // 递归看 .wine-{uid} 子目录
      for (const e of list) {
        if (!e.startsWith('.wine')) continue;
        const sub: string = `${tmp}/${e}`;
        this.append(`\n-- ${sub} --`);
        try {
          const slist: string[] = fs.listFileSync(sub);
          for (const s of slist) {
            const sp: string = `${sub}/${s}`;
            try {
              const sst = fs.statSync(sp);
              const kind: string = sst.isDirectory() ? 'D' :
                sst.isSocket() ? 'S' : 'F';
              this.append(`  ${kind} ${s} (${sst.size}b)`);
            } catch (er) {
              this.append(`  ? ${s}`);
            }
          }
          // 再下一层 (server-xxx-yyy)
          for (const s of slist) {
            const ssub: string = `${sub}/${s}`;
            try {
              const ssst = fs.statSync(ssub);
              if (!ssst.isDirectory()) continue;
              const sslist: string[] = fs.listFileSync(ssub);
              this.append(`  -- ${ssub} --`);
              for (const ss of sslist) {
                const ssp: string = `${ssub}/${ss}`;
                try {
                  const sssst = fs.statSync(ssp);
                  const kind: string = sssst.isDirectory() ? 'D' :
                    sssst.isSocket() ? 'S' : 'F';
                  this.append(`    ${kind} ${ss} (${sssst.size}b)`);
                } catch (er) {
                  this.append(`    ? ${ss}`);
                }
              }
            } catch (er) { /* skip */ }
          }
        } catch (er) {
          this.append(`(list err: ${(er as Error).message})`);
        }
      }
    } catch (e) {
      this.append(`(err: ${(e as Error).message})`);
    }
  }

  // 单独跑 wineserver 不带 client, 看它独立启动是否健康
  // wineserver -f = foreground, -d = debug log
  private async secWineserverFg(): Promise<void> {
    this.append('===== wineserver -f (foreground 5s) =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const wineserver: string = `${WineService.getRootDir(ctx)}/bin/wineserver`;

    const env: string[] = this.buildEnv('1');
    const args: string[] = ['box64', wineserver, '-f', '-d'];

    let pid: number = 0;
    const ended: GeneratedTypeLiteralInterface_1 = { v: false };

    await new Promise<void>((resolve): void => {
      const cb = (event: string, data: string): void => {
        if (event === 'out') {
          const line: string = data.endsWith('\n') ? data.substring(0, data.length - 1) : data;
          this.append(line);
        } else if (event === 'exit') {
          ended.v = true;
          this.append(`[exit=${data}]`);
          resolve();
        }
      };
      pid = wl.runBox64('box64', args, env, '', cb);
      if (pid <= 0) {
        this.append(`[run error] pid=${pid}`);
        resolve();
        return;
      }
      this.append(`[pid=${pid}] launched`);
      // 5 秒后强制 stop, foreground 模式不会自己退出
      setTimeout((): void => {
        if (!ended.v) {
          this.append(`[stopping after 5s]`);
          wl.terminate(pid);
        }
      }, 5000);
    });
  }

  // 后台拉起 wineserver -f -p (前台模式 + 永久持续, 不主动退出)
  // 这样后续 wine 调用会复用这个 server, 跳过 daemonize 路径
  private startWineserverBg(): void {
    if (this.wineserverPid > 0) {
      this.append(`[ws] already running pid=${this.wineserverPid}`);
      return;
    }
    this.append('===== START WINESERVER (bg) =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const wineserver: string = `${WineService.getRootDir(ctx)}/bin/wineserver`;

    const env: string[] = this.buildEnv('1');
    // -f 前台 (不 daemonize), -p 永久 persist
    const args: string[] = ['box64', wineserver, '-f', '-p'];

    const cb = (event: string, data: string): void => {
      if (event === 'out') {
        const line: string = data.endsWith('\n') ? data.substring(0, data.length - 1) : data;
        this.append(`[ws] ${line}`);
      } else if (event === 'exit') {
        this.append(`[ws] exit=${data}`);
        this.wineserverPid = 0;
      }
    };
    const pid: number = wl.runBox64('box64', args, env, '', cb);
    if (pid > 0) {
      this.wineserverPid = pid;
      this.append(`[ws] started pid=${pid}`);
    } else {
      this.append(`[ws] launch error pid=${pid}`);
    }
  }

  private startWineserverBgSilent(): void {
    if (this.wineserverPid > 0) {
      this.append(`[ws] already running pid=${this.wineserverPid}`);
      return;
    }
    this.append('===== START WINESERVER (silent) =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const wineserver: string = `${WineService.getRootDir(ctx)}/bin/wineserver`;

    const env: string[] = this.buildEnv('0');
    const args: string[] = ['box64', wineserver, '-f', '-p'];

    // 用一个声明为可选/可空的类型变量, 而不是 any/unknown
    const noCb: ((event: string, data: string) => void) | null = null;
    const pid: number = wl.runBox64('box64', args, env, '', noCb);

    if (pid > 0) {
      this.wineserverPid = pid;
      this.append(`[ws-silent] started pid=${pid} (output -> /dev/null)`);
      this.append(`(静默模式无 exit 通知, 子进程真死后请手动 "停 wineserver")`);
    } else {
      this.append(`[ws-silent] launch error pid=${pid}`);
    }
  }

  private stopWineserverBg(): void {
    if (this.wineserverPid > 0) {
      try {
        wl.terminate(this.wineserverPid);
        this.append(`[ws] terminate sent to ${this.wineserverPid}`);
      } catch (e) {
        this.append(`[ws] terminate err: ${(e as Error).message}`);
      }
      this.wineserverPid = 0;
    } else {
      this.append('[ws] not running');
    }
  }

  // 在已有后台 wineserver 的前提下跑 wineboot
  // 也启用 WINEDEBUG=+server,+process 看协议握手细节
  private async secWinebootWithServer(): Promise<void> {
    const timeoutMs: number = 90 * 1000;
    const startTs: number = Date.now();
    if (this.wineserverPid <= 0) {
      this.append('[err] wineserver 未启动, 先点 "起 wineserver"');
      return;
    }
    this.append('===== wineboot (复用现有 wineserver) =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const wineBin: string = WineService.getBinPath(ctx);

    const env: string[] = this.buildEnv('1')
      .concat(WaylandService.getInstance().getWaylandEnv())
      .concat(['WINEDEBUG=+server,+process']);

    const args: string[] = ['box64', wineBin, 'wineboot', '--init'];

    const startMs: number = Date.now();
    await new Promise<void>((resolve): void => {
      let settled: boolean = false;
      let ticker: number = 0;
      const done = (reason: string): void => {
        if (settled) return;
        settled = true;
        if (ticker !== 0) {
          clearInterval(ticker);
          ticker = 0;
        }
        this.append(`[done] ${reason}`);
        resolve();
      };

      const cb = (event: string, data: string): void => {
        if (event === 'out') {
          const line: string = data.endsWith('\n') ? data.substring(0, data.length - 1) : data;
          this.append(line);
        } else if (event === 'exit') {
          const code: number = parseInt(data, 10);
          const cost: number = (Date.now() - startMs) / 1000;
          this.append(`[exit=${code}] (${cost.toFixed(1)}s)`);
          done('child exit event');
        }
      };
      const pid: number = wl.runBox64('box64', args, env, '', cb);
      if (pid <= 0) {
        this.append(`[run err] pid=${pid}`);
        done('launch failed');
        return;
      }
      this.append(`[client pid=${pid}]`);

      ticker = setInterval((): void => {
        if (settled) {
          clearInterval(ticker);
          ticker = 0;
          return;
        }
        const dt: number = Date.now() - startTs;
        if (dt > timeoutMs) {
          this.append(`[timeout ${(dt/1000).toFixed(0)}s] killing wineboot pid=${pid}...`);
          try { wl.terminate(pid); } catch (e) { /* ignore */ }
          // 给 napi 一点时间收 SIGCHLD; 若 5s 内仍未收到 exit 事件就强制 resolve
          setTimeout((): void => {
            if (!settled) {
              this.append('[timeout] no exit event after kill, force resolve');
              done('forced after timeout');
            }
          }, 5000);
        }
      }, 5000) as number;
    });
  }

  private secWinePrefixHealth(): void {
    this.append('===== WINEPREFIX HEALTH =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const prefix: string = WineService.getPrefixDir(ctx);

    interface Check { path: string; desc: string; mustExist: boolean; }
    const checks: Check[] = [
      { path: `${prefix}/system.reg`,     desc: 'system.reg',     mustExist: true },
      { path: `${prefix}/user.reg`,       desc: 'user.reg',       mustExist: true },
      { path: `${prefix}/userdef.reg`,    desc: 'userdef.reg',    mustExist: true },
      { path: `${prefix}/.update-timestamp`, desc: 'update-stamp', mustExist: true },
      { path: `${prefix}/drive_c/windows/system32`, desc: 'system32 dir', mustExist: true },
      { path: `${prefix}/drive_c/users`,  desc: 'users dir',      mustExist: true },
    ];

    let pass: number = 0;
    let fail: number = 0;
    for (const c of checks) {
      const exists: boolean = fs.accessSync(c.path);
      let size: number = -1;
      if (exists) {
        try {
          const st = fs.statSync(c.path);
          size = st.size;
        } catch (e) { /* dir */ }
      }
      const tag: string = exists ? 'OK ' : 'NO ';
      this.append(`  ${tag} ${c.desc.padEnd(20)} size=${size} ${c.path}`);
      if (exists) pass++; else fail++;
    }

    // 统计 system32 里的文件数
    try {
      const sys32: string = `${prefix}/drive_c/windows/system32`;
      const ent: string[] = fs.listFileSync(sys32);
      this.append(`  system32 entries: ${ent.length}`);
      // 找几个关键 fakedll
      const keyDlls: string[] = ['kernel32.dll', 'ntdll.dll', 'user32.dll', 'cmd.exe'];
      for (const d of keyDlls) {
        const ok: boolean = fs.accessSync(`${sys32}/${d}`);
        this.append(`    ${ok ? 'YES' : 'NO '} ${d}`);
      }
    } catch (e) {
      this.append(`  system32 scan err: ${(e as Error).message}`);
    }

    // 检查 wineboot 是否真走完
    try {
      const ts: string = `${prefix}/.update-timestamp`;
      if (fs.accessSync(ts)) {
        const st = fs.statSync(ts);
        const ageS: number = (Date.now() - st.mtime * 1000) / 1000;
        this.append(`  update-timestamp age: ${ageS.toFixed(0)}s ago`);
        if (ageS < 300) {
          this.append('  >>> wineboot ran in last 5 min, likely OK <<<');
        }
      }
    } catch (e) { /* skip */ }

    this.append(`总结: ${pass} pass, ${fail} fail`);
  }

  private async secWineCmd(): Promise<void> {
    if (this.wineserverPid <= 0) {
      this.append('[err] wineserver 未启动, 先点 "起 wineserver"');
      return;
    }
    this.append('===== wine cmd /c echo hello =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const wineBin: string = WineService.getBinPath(ctx);

    const env: string[] = this.buildEnv('1')
      .concat(WaylandService.getInstance().getWaylandEnv())
      .concat(['WINEDEBUG=+process']);

    // cmd /c echo hello 是最小 PE 加载 + 单条命令 + 立刻退出
    const args: string[] = ['box64', wineBin, 'cmd', '/c', 'echo', 'hello from wine'];

    const timeoutMs: number = 30 * 1000;
    const startMs: number = Date.now();

    await new Promise<void>((resolve): void => {
      let settled: boolean = false;
      let pid: number = 0;
      const done = (reason: string): void => {
        if (settled) return;
        settled = true;
        this.append(`[done] ${reason}`);
        resolve();
      };

      const cb = (event: string, data: string): void => {
        if (event === 'out') {
          const line: string = data.endsWith('\n') ? data.substring(0, data.length - 1) : data;
          this.append(line);
        } else if (event === 'exit') {
          const code: number = parseInt(data, 10);
          const cost: number = (Date.now() - startMs) / 1000;
          this.append(`[exit=${code}] (${cost.toFixed(1)}s)`);
          done('child exit');
        }
      };
      pid = wl.runBox64('box64', args, env, '', cb);
      if (pid <= 0) {
        this.append(`[run err] pid=${pid}`);
        done('launch failed');
        return;
      }
      this.append(`[client pid=${pid}]`);

      setTimeout((): void => {
        if (settled) return;
        this.append(`[timeout ${(timeoutMs/1000)}s] killing pid=${pid}...`);
        try { wl.terminate(pid); } catch (e) { /* ignore */ }
        setTimeout((): void => {
          if (!settled) {
            this.append('[timeout] forcing resolve');
            done('forced timeout');
          }
        }, 3000);
      }, timeoutMs);
    });
  }

  private async secWineboot(): Promise<void> {
    this.append('===== box64 wine wineboot --init =====');
    this.append('(实时输出, 可能耗时 30 秒以上)');

    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const wineBin: string = WineService.getBinPath(ctx);
    const env: string[] = this.buildEnv('1')
      .concat(WaylandService.getInstance().getWaylandEnv());
    const args: string[] = ['box64', wineBin, 'wineboot', '--init'];

    const startMs: number = Date.now();

    await new Promise<void>((resolve): void => {
      const cb = (event: string, data: string): void => {
        if (event === 'out') {
          // 兼容 data 末尾可能带 \n 的情况, 避免出现空行
          const line: string = data.endsWith('\n')
            ? data.substring(0, data.length - 1)
            : data;
          this.append(line);
        } else if (event === 'exit') {
          const code: number = parseInt(data, 10);
          const cost: number = ((Date.now() - startMs) / 1000);
          this.append(`[exit=${code}] (${cost.toFixed(1)}s)`);
          resolve();
        }
      };

      const pid: number = wl.runBox64('box64', args, env, '', cb);
      if (pid <= 0) {
        this.append(`[run error] pid=${pid}`);
        resolve();
      } else {
        this.append(`[pid=${pid}] launched, streaming...`);
      }
    });
  }

  // 临时给 DebugPage 加个按钮看 wineserver 跑没跑
  private async secWineserverProbe(): Promise<void> {
    this.append('===== wineserver alive? =====');
    const r = await this.runBox64Capture(
      ['box64', 'sh', '-c', 'ps -ef 2>/dev/null | grep -i wine'],
      this.buildEnv('1'), ''
    );
    this.append(r);
  }

  private secStartSock(): void {
    this.append('===== START PROCMGR SOCK =====');
    this.append(`path = ${this.procSockPath}`);
    if (this.sockStarted) {
      this.append('(already started, skip)');
      return;
    }
    let ok: boolean = false;
    try {
      ok = wl.startProcMgr(this.procSockPath);
    } catch (e) {
      this.append(`[err] ${(e as Error).message}`);
      return;
    }
    this.sockStarted = ok;
    this.append(ok ? '[ok] listening' : '[fail] start returned false');
    // 启动后, 后续 box64 子进程的 BOX64_SPAWN_STRATEGY=sock 才能走通.
    // 当前 buildEnv 没设这个环境变量, 默认就是 sock, 直接生效.
  }

  private secStopSock(): void {
    this.append('===== STOP PROCMGR SOCK =====');
    try {
      wl.stopProcMgr();
    } catch (e) {
      this.append(`[err] ${(e as Error).message}`);
      return;
    }
    this.sockStarted = false;
    this.append('[ok] stopped');
  }

  private async secReinstallWine(): Promise<void> {
    this.append('===== 替换 WINE (新版) =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;

    // 1) 安全闸门: 必须先停 wineserver, 否则旧 server 句柄拿着旧 wine .so 不放
    if (this.wineserverPid > 0) {
      this.append('[1/5] 检测到 wineserver 运行中, 先停掉');
      this.stopWineserverBg();
      // 给它 1 秒退出, 否则下一步 rmdir 可能撞到 busy
      await new Promise<void>((r): void => { setTimeout(r, 1000); });
    } else {
      this.append('[1/5] wineserver 未在跑, 跳过');
    }

    // 2) 清旧 wineprefix
    this.append('[2/5] 清理旧 wineprefix');
    try {
      WineService.wipePrefix(ctx);
      this.append('     prefix wiped');
    } catch (e) {
      this.append(`     wipe err: ${(e as Error).message}`);
    }

    // 2.1) 显式删 setup marker (即使 wipePrefix 不干净也保证下次重做)
    const prefix: string = WineService.getPrefixDir(ctx);
    const marker: string = `${prefix}/.box64_setup_done`;
    try {
      if (fs.accessSync(marker)) {
        fs.unlinkSync(marker);
        this.append('     marker removed');
      }
    } catch (e) { /* ignore */ }

    // 2.5) 清 box64-tmp (wineserver 的 /tmp 替身, 有旧 socket/lock)
    this.append('[2.5/5] 清理 box64-tmp');
    const box64Tmp: string = '/data/storage/el2/base/cache/box64-tmp';
    try {
      if (fs.accessSync(box64Tmp)) {
        fs.rmdirSync(box64Tmp);
        this.append('     box64-tmp wiped');
      } else {
        this.append('     box64-tmp not present');
      }
    } catch (e) {
      this.append(`     wipe err: ${(e as Error).message}`);
    }

    // 3) 卸载旧 wine 目录
    this.append('[3/5] 卸载旧 wine');
    try {
      WineService.uninstall(ctx);
      this.append('     uninstalled');
    } catch (e) {
      this.append(`     uninstall err: ${(e as Error).message}`);
    }

    // 4) 选目录 + 安装新版
    this.append('[4/5] 选择新版 wine 根目录 (含 bin/wine)');
    const msg: string = await WineService.pickAndInstall(ctx);
    if (msg.length > 0) {
      this.append(`     失败: ${msg}`);
      return;
    }
    this.append('     install ok');

    // 5) 重新预布置 prefix
    this.append('[5/5] 预布置新 prefix');
    // const prefix: string = WineService.getPrefixDir(ctx);
    const wineRoot: string = WineService.getRootDir(ctx);
    try {
      const ok: boolean = wl.setupWinePrefix(prefix, wineRoot);
      this.append(`     setupWinePrefix = ${ok ? 'OK' : 'FAIL'}`);
    } catch (e) {
      this.append(`     setup err: ${(e as Error).message}`);
    }

    this.append('');
    this.append('done. 下一步: 起 wineserver -> wineboot (复用 ws)');
  }

  private async runOne(fn: () => Promise<void>): Promise<void> {
    if (this.running) return;
    this.running = true;
    try { await fn(); }
    catch (e) { this.append(`[unexpected] ${JSON.stringify(e)}`); }
    finally { this.running = false; }
  }

  private async runAll(): Promise<void> {
    if (this.running) return;
    this.running = true;
    this.clear();
    try {
      await this.secEnv();          this.append('');
      await this.secWineFiles();    this.append('');
      await this.secWayland();      this.append('');
      await this.secResources();    this.append('');
      await this.secBox64();        this.append('');
      await this.secWineVersion();  this.append('');
      await this.secWineserver();   this.append('');
      await this.secPrefix();
    } finally { this.running = false; }
  }

  private copy(): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.output);
    pasteboard.getSystemPasteboard().setData(data, (err): void => {
      if (!err) {
        this.copyHint = true;
        setTimeout((): void => { this.copyHint = false; }, 1500);
      }
    });
  }

  build() {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Text('🔧 调试诊断')
            .fontSize(22).fontWeight(FontWeight.Bold)
          Text('排查 wine on box64 及 wayland 状态')
            .fontSize(11).fontColor('#999999')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.running) { LoadingProgress().width(20).height(20) }
      }
      .width('100%').margin({ bottom: 14 })

      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
        Button('环境').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secEnv()); })
        Button('Wine 文件').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secWineFiles()); })
        Button('Wayland').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secWayland()); })
        Button('资源').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secResources()); })
        Button('box64').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secBox64()); })
        Button('wine -v').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secWineVersion()); })
        Button('prefix').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secPrefix()); })
        Button('预布置 prefix').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secSetupPrefix(false)); })
        Button('强制重布').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor('#F0F0F0').fontColor('#333333').enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secSetupPrefix(true)); })
        Button('起 wineserver').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running && this.wineserverPid === 0)
          .onClick((): void => { this.startWineserverBg(); })
        Button('🔇 起 wineserver (静默)').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running && this.wineserverPid === 0)
          .onClick((): void => { this.startWineserverBgSilent(); })
        Button('停 wineserver').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor('#F0F0F0').fontColor('#333333').enabled(!this.running && this.wineserverPid > 0)
          .onClick((): void => { this.stopWineserverBg(); })
        Button('wineboot (复用 ws)').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running && this.wineserverPid > 0)
          .onClick((): void => { this.runOne((): Promise<void> => this.secWinebootWithServer()); })
        Button('wineprefix 健康').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor('#F0F0F0').fontColor('#333333').enabled(!this.running)
          .onClick((): void => { this.secWinePrefixHealth(); })
        Button('wine cmd').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE)
          .enabled(!this.running && this.wineserverPid > 0)
          .onClick((): void => { this.runOne((): Promise<void> => this.secWineCmd()); })
        Button(this.sockStarted ? '✓ ProcMgr Sock' : '起 ProcMgr Sock').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(this.sockStarted ? '#5DD46E' : Theme.HM_BLUE)
          .enabled(!this.running && !this.sockStarted)
          .onClick((): void => { this.secStartSock(); })
        Button('停 ProcMgr Sock').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor('#F0F0F0').fontColor('#333333')
          .enabled(!this.running && this.sockStarted)
          .onClick((): void => { this.secStopSock(); })
        Button('🔄 替换 Wine').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor('#E8743C').fontColor(Color.White)
          .enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secReinstallWine()); })
      }
      .width('100%').margin({ bottom: 4 })

      Row({ space: 8 }) {
        Button('清空').fontSize(12).height(28)
          .backgroundColor('#F0F0F0').fontColor('#333333')
          .onClick((): void => { this.clear(); })
        Button(this.copyHint ? '已复制' : '复制全部').fontSize(12).height(28)
          .backgroundColor(this.copyHint ? '#5DD46E' : '#1A8F4D')
          .fontColor(Color.White)
          .onClick((): void => { this.copy(); })
        Button('全部').fontSize(12).height(28)
          .backgroundColor(Theme.HM_BLUE)
          .fontColor(Color.White)
          .onClick((): void => { this.runAll(); })
      }
      .width('100%').margin({ bottom: 8 })

      Scroll(this.scroller) {
        Text(this.output.length > 0 ? this.output : '点击上方按钮开始诊断')
          .fontSize(11).fontFamily('monospace').fontColor('#E0E0E0')
          .width('100%').textAlign(TextAlign.Start)
          .copyOption(CopyOptions.LocalDevice)
      }
      .layoutWeight(1).width('100%').padding(12)
      .backgroundColor('#0E0E0E').borderRadius(8)
      .scrollBar(BarState.Auto).align(Alignment.TopStart)
    }
    .width('100%').height('100%')
    .alignItems(HorizontalAlign.Start)
  }
}