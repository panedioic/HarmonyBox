import { webview } from '@kit.ArkWeb';
import { ShellEngine } from '../shell/ShellEngine';
import { common } from '@kit.AbilityKit';

@Component
export struct DebugShellPage {
  private controller: webview.WebviewController = new webview.WebviewController();
  private engine: ShellEngine | null = null;
  @State pageReady: boolean = false;

  aboutToDisappear(): void {
    this.engine = null;
  }

  build() {
    Column() {
      Row() {
        Text('🐚 调试终端')
          .fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor('#E0E0E0')
        Blank()
        Text(this.pageReady ? '● 已就绪' : '○ 加载中')
          .fontSize(11)
          .fontColor(this.pageReady ? '#5DD46E' : '#999999')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor('#1A1A1A')

      Web({
        src: $rawfile('term/index.html'),
        controller: this.controller
      })
        .layoutWeight(1)
        .width('100%')
        .darkMode(WebDarkMode.On)
        .domStorageAccess(true)
        .javaScriptAccess(true)
        .javaScriptProxy({
          object: {
            input: (data: string): void => {
              this.engine?.feed(data);
            }
          },
          name: 'hbridge',
          methodList: ['input'],
          controller: this.controller
        })
        .onPageEnd((): void => {
          this.pageReady = true;
          const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
          this.engine = new ShellEngine(this.controller, ctx);
          this.engine.start();
          // 把启动期间堆积的输入冲洗一下
          this.controller.runJavaScript('window.flushPendingInput && window.flushPendingInput()');
        })
    }
    .width('100%').height('100%')
    .backgroundColor('#0E0E0E')
  }
}