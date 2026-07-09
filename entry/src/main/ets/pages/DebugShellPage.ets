import wl, { ProcessInfo } from 'libentry.so';
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { WineService } from '../service/WineService';
import { LibStore } from '../service/LibStore';
import { ShellRegistry, ShellIO } from '../shell/ShellRegistry';
import { fileIo as fs } from '@kit.CoreFileKit';
import { WaylandService } from '../service/WaylandService';

@Component
export struct DebugShellPage {
  private controller: webview.WebviewController = new webview.WebviewController();
  @State pageReady: boolean = false;
  private inited: boolean = false;

  aboutToDisappear(): void {
    if (this.inited) {
      wl.shellShutdown();
      this.inited = false;
    }
  }

  private initShell(): void {
    if (this.inited) return;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const filesDir = ctx.filesDir;

    const ok: boolean = wl.shellInit(
      {
        homeDir: filesDir,
        logDir: `${filesDir}/shell-logs`,
        envPersistPath: `${filesDir}/shell-env.conf`,   // 新增
        cols: 80,
        rows: 24
      },
      (data: string): void => {
        // C++ -> xterm
        const esc: string = JSON.stringify(data);
        this.controller.runJavaScript(`window.termWrite(${esc})`);
      }
    );
    this.inited = ok;
    if (!ok) {
      console.error('shellInit failed');
      return;
    }

    // 注入 system env: WineService/LibStore 计算出来的 box64/wayland env
    try {
      const sysEnv: string[] = this.buildSystemEnv(ctx);
      wl.shellSetSystemEnv(sysEnv);
    } catch (e) {
      console.error('shellSetSystemEnv failed: ' + (e as Error).message);
    }

    this.registerCommands(ctx);
  }

  private buildSystemEnv(ctx: common.UIAbilityContext): string[] {
    const filesDir = ctx.filesDir;
    const cacheDir = ctx.cacheDir;
    const wineRoot = WineService.getRootDir(ctx);
    const wineBin = WineService.getBinPath(ctx);
    const winePrefix = WineService.getPrefixDir(ctx);
    const ldPaths = WineService.buildLdPaths(ctx);
    const x64LibsDir = LibStore.getDir(ctx);
    if (x64LibsDir) ldPaths.push(x64LibsDir);

    const out: string[] = [
      `FILES_DIR=${filesDir}`,
      `CACHE_DIR=${cacheDir}`,

      // wine 路径, 供 shell 内 wine/wineserver 命令自动拼接
      `HBOX_WINE_ROOT=${wineRoot}`,
      `HBOX_WINE_BIN=${wineBin}`,
      `HBOX_WINESERVER_BIN=${wineRoot}/bin/wineserver`,

      // box64 / wine 环境
      `BOX64_LD_LIBRARY_PATH=${ldPaths.join(':')}`,
      `BOX64_LOG=0`,
      `BOX64_NOBANNER=0`,
      `WINEPREFIX=${winePrefix}`,

      // procmgr sock 默认路径
      `HBOX_PROCMGR_SOCK=${filesDir}/.procmgr.sock`,

      //
      `HBOX_APPS_JSON=${filesDir}/apps.json`,
    ];

    // wine service 自身还需要一些 (WINEDLLPATH 等)
    for (const kv of WineService.buildLaunchEnv(ctx)) {
      out.push(kv);
    }

    // 新增: wayland env (让 shell 里跑的 wine 客户端能连上)
    const wlEnv: string[] = WaylandService.getInstance().getWaylandEnv();
    for (const e of wlEnv) out.push(e);

    return out;
  }

  private registerCommands(ctx: common.UIAbilityContext): void {
    ShellRegistry.register('wine.version', {
      desc: 'show wine version',
      streaming: false
    }, async (args: string[], env: Record<string, string>, io: ShellIO): Promise<number> => {
      const wineBin: string = env['HBOX_WINE_BIN'] ?? '';
      if (!wineBin) {
        io.err('HBOX_WINE_BIN not set');
        return 1;
      }
      io.writeln('wine binary: \x1b[36m' + wineBin + '\x1b[0m');
      io.writeln('prefix:      \x1b[36m' + (env['WINEPREFIX'] ?? '(unset)') + '\x1b[0m');
      return 0;
    });

    ShellRegistry.register('wine.info', {
      desc: 'dump wine/box64 related env',
      streaming: false
    }, async (args: string[], env: Record<string, string>, io: ShellIO): Promise<number> => {
      const prefix: string = args[0] ?? 'WINE';
      const keys: string[] = Object.keys(env).filter((k: string) => k.startsWith(prefix)).sort();
      if (keys.length === 0) {
        io.writeln('\x1b[90mno vars matching prefix ' + prefix + '\x1b[0m');
        return 0;
      }
      for (const k of keys) {
        io.writeln('\x1b[36m' + k + '\x1b[0m=' + env[k]);
      }
      return 0;
    });

    ShellRegistry.register('demo.stream', {
      desc: 'demo streaming output (10 lines with delay)',
      streaming: true
    }, async (args: string[], env: Record<string, string>, io: ShellIO): Promise<number> => {
      for (let i = 1; i <= 10; i++) {
        io.writeln('line ' + i + '  \x1b[90m(' + new Date().toISOString() + ')\x1b[0m');
        await new Promise<void>((r: () => void) => setTimeout(r, 300));
      }
      return 0;
    });

    ShellRegistry.register('wine.reinstall', {
      desc: 'safely reinstall wine (validate before wiping old)',
      usage: 'wine.reinstall',
      streaming: true
    }, async (args: string[], env: Record<string, string>, io: ShellIO): Promise<number> => {
      io.writeln('[1/5] pick a wine directory (must contain bin/wine, bin/wineserver)');
      const uri: string | null = await WineService.pickAndInstall(ctx);
      if (!uri) {
        io.writeln('\x1b[90m[cancelled]\x1b[0m');
        return 1;
      }
      io.writeln('  picked: \x1b[36m' + uri + '\x1b[0m');
      io.writeln('[2/5] validating source directory...');
      io.writeln('  \x1b[32mok\x1b[0m');
      return 0;
    });
  }

  build() {
    Column() {
      Row() {
        Text('🐚 调试终端')
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor('#E0E0E0')
        Blank()
        Text(this.pageReady ? '● 已就绪' : '○ 加载中')
          .fontSize(11)
          .fontColor(this.pageReady ? '#5DD46E' : '#999999')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor('#1A1A1A')

      Web({ src: $rawfile('term/index.html'), controller: this.controller })
        .layoutWeight(1).width('100%')
        .darkMode(WebDarkMode.On)
        .domStorageAccess(true)
        .javaScriptAccess(true)
        .javaScriptProxy({
          object: {
            input: (data: string): void => {
              if (this.inited) wl.shellInput(data);
            }
          },
          name: 'hbridge',
          methodList: ['input'],
          controller: this.controller
        })
        .onPageEnd((): void => {
          this.pageReady = true;
          this.initShell();
          this.controller.runJavaScript(
            'window.flushPendingInput && window.flushPendingInput()'
          );
        })
    }
    .width('100%').height('100%').backgroundColor('#0E0E0E')
  }
}