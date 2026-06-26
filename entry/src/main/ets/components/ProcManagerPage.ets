import { Theme } from '../common/Theme';
import { BusinessError } from '@kit.BasicServicesKit';
import wl from 'libentry.so';

// 导入接口类型声明 (确保与你 index.d.ts 里的定义保持一致)
interface ProcessInfo {
  pid: number;
  parentPid: number;
  kind: 'native' | 'box64';
  exePath: string;
  startTimeMs: number;
  exitCode: number;
  alive: boolean;
}

@Component
export struct ProcManagerPage {
  @State procList: ProcessInfo[] = [];
  private timerId: number = -1;

  aboutToAppear(): void {
    this.refreshList();
    // 每 2 秒拉取一次进程列表
    this.timerId = setInterval(() => this.refreshList(), 2000);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private refreshList(): void {
    try {
      const list = wl.listProcesses() as ProcessInfo[];
      // 排序: 存活在最前, PID 大的 (通常较新) 靠前
      this.procList = list.sort((a: ProcessInfo, b: ProcessInfo): number => {
        if (a.alive !== b.alive) return a.alive ? -1 : 1;
        return b.pid - a.pid;
      });
    } catch (e) {
      const err = e as BusinessError;
      console.error(`listProcesses failed: ${err.code}, ${err.message}`);
    }
  }

  private killProcess(pid: number): void {
    try {
      wl.terminate(pid);
      // 发送 kill 信号后，延迟一会再刷新，等 procmgr 内部状态更迭
      setTimeout(() => this.refreshList(), 300);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`terminate failed: ${err.code}, ${err.message}`);
    }
  }

  private formatDuration(startMs: number): string {
    if (startMs <= 0) return '未知';
    const diff = Date.now() - startMs;
    const sec = Math.floor(diff / 1000);
    const min = Math.floor(sec / 60);
    const hour = Math.floor(min / 60);
    if (hour > 0) return `${hour}h ${min % 60}m`;
    if (min > 0) return `${min}m ${sec % 60}s`;
    return `${sec}s`;
  }

  build() {
    Column() {
      // 顶部标题栏
      Row() {
        Text('进程管理器').fontSize(22).fontWeight(FontWeight.Bold).fontColor(Theme.HM_BLUE)
        Blank()
        Button('刷新')
          .fontSize(14)
          .height(32)
          .borderRadius(8)
          .backgroundColor(Theme.HM_BLUE)
          .fontColor(Color.White)
          .onClick(() => this.refreshList())
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })

      // 进程列表区域
      if (this.procList.length === 0) {
        Column() {
          Text('当前没有运行中的进程').fontSize(14).fontColor('#999999')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 12 }) {
          ForEach(this.procList, (proc: ProcessInfo) => {
            ListItem() {
              this.ProcCard(proc)
            }
          }, (proc: ProcessInfo) => `${proc.pid}_${proc.alive}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, bottom: 16 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.HM_BG)
  }

  @Builder
  ProcCard(proc: ProcessInfo) {
    Row() {
      Column() {
        Row() {
          Text(`PID: ${proc.pid}`).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#333333')
          Text(`(${proc.kind})`).fontSize(12).fontColor('#999999').margin({ left: 8 })
          Blank()
          if (proc.alive) {
            Row() {
              Text('').width(6).height(6).borderRadius(3).backgroundColor('#52C41A').margin({ right: 6 })
              Text('运行中').fontSize(12).fontColor('#52C41A')
            }
          } else {
            Row() {
              Text('').width(6).height(6).borderRadius(3).backgroundColor('#FF4D4F').margin({ right: 6 })
              Text('已退出').fontSize(12).fontColor('#FF4D4F')
            }
          }
        }
        .width('100%')

        Text(proc.exePath).fontSize(12).fontColor('#666666')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6, bottom: 4 })

        Row() {
          Text(`已运行: ${this.formatDuration(proc.startTimeMs)}`).fontSize(11).fontColor('#999999')
          if (!proc.alive) {
            Text(`退出码: ${proc.exitCode}`).fontSize(11).fontColor('#999999').margin({ left: 16 })
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 在右侧显示 Kill 按钮
      if (proc.alive) {
        Button('强制结束')
          .fontSize(13)
          .height(32)
          .borderRadius(16)
          .backgroundColor('#FF4D4F')
          .fontColor(Color.White)
          .margin({ left: 12 })
          .onClick(() => this.killProcess(proc.pid))
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(8)
    .backgroundColor(Color.White)
    .shadow({ radius: 4, color: '#1A000000', offsetX: 0, offsetY: 2 })
  }
}