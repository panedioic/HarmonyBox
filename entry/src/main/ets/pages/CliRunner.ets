import { CliService, CliSubscriber } from '../service/CliService';
import { pasteboard } from '@kit.BasicServicesKit';

@Entry
@Component
struct CliRunner {
  @State appName: string = '应用';
  @State lines: string[] = [];
  @State exited: boolean = false;
  @State exitCode: number = 0;
  @State copyHint: boolean = false;

  private pid: number = -1;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const name = AppStorage.get<string>('currentAppName');
    if (name) this.appName = name;

    const pid = AppStorage.get<number>('currentCliPid');
    if (typeof pid !== 'number' || pid <= 0) {
      this.lines = ['[错误] 未获取到运行进程'];
      this.exited = true;
      return;
    }
    this.pid = pid;

    const sub: CliSubscriber = {
      onLine: (line: string): void => {
        this.lines = [...this.lines, line];
        setTimeout((): void => {
          this.scroller.scrollEdge(Edge.Bottom);
        }, 0);
      },
      onExit: (code: number): void => {
        if (this.exited) return;
        this.exited = true;
        this.exitCode = code;
        this.lines = [...this.lines, '', `[进程已退出, 退出码 ${code}]`];
      }
    };
    const initial: string[] = CliService.getInstance().subscribe(this.pid, sub);
    this.lines = initial;
  }

  aboutToDisappear(): void {
    if (this.pid > 0) {
      const svc = CliService.getInstance();
      svc.unsubscribe(this.pid);
      if (!this.exited) svc.stop(this.pid);
      svc.clear(this.pid);
    }
  }

  copyAll(): void {
    const text: string = this.lines.join('\n');
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data, (err): void => {
      if (!err) {
        this.copyHint = true;
        setTimeout((): void => { this.copyHint = false; }, 1500);
      }
    });
  }

  build() {
    Column() {
      // 顶部状态条
      Row() {
        Text('▣')
          .fontSize(13)
          .fontColor(this.exited ? '#888888' : '#5DD46E')
          .margin({ right: 8 })
        Text(this.appName)
          .fontSize(13)
          .fontColor('#DDDDDD')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.exited) {
          Text(`已退出 (${this.exitCode})`)
            .fontSize(11)
            .fontColor('#FF8888')
            .margin({ right: 8 })
        } else {
          Text(`PID ${this.pid}`)
            .fontSize(11)
            .fontColor('#888888')
            .margin({ right: 8 })
        }

        Text(this.copyHint ? '已复制' : '复制')
          .fontSize(11)
          .fontColor(this.copyHint ? '#5DD46E' : '#AAAAAA')
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor('#2A2A2A')
          .borderRadius(4)
          .onClick((): void => { this.copyAll(); })
      }
      .width('100%')
      .height(36)
      .padding({ left: 12, right: 12 })
      .backgroundColor('#1F1F1F')

      // 终端输出
      Scroll(this.scroller) {
        Column() {
          ForEach(this.lines, (line: string, i: number): void => {
            Text(line.length > 0 ? line : ' ')
              .fontSize(12)
              .fontFamily('monospace')
              .fontColor('#E0E0E0')
              .width('100%')
              .textAlign(TextAlign.Start)
              .copyOption(CopyOptions.LocalDevice)
          }, (line: string, i: number): string => `${i}`)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#0E0E0E')
      .scrollBar(BarState.Auto)
      .scrollBarColor('#444444')
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
  }
}