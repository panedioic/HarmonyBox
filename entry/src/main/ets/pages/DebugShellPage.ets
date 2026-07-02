import wl from 'libentry.so';
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { WineService } from '../service/WineService';
import { LibStore } from '../service/LibStore';

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
    ];

    // wine service 自身还需要一些 (WINEDLLPATH 等)
    for (const kv of WineService.buildLaunchEnv(ctx)) {
      out.push(kv);
    }
    return out;
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