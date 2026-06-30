import wl from 'libentry.so';
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';

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
    const ok: boolean = wl.shellInit(
      {
        homeDir: ctx.filesDir,
        logDir: `${ctx.filesDir}/shell-logs`,
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
    }
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