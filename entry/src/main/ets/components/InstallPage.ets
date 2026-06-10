import { Theme } from '../common/Theme';

@Component
export struct InstallPage {
  @State progressVisible: boolean = false;
  @State progress: number = 0;
  @State statusText: string = '正在同步至沙箱...';
  @State highlight: boolean = false;
  onInstalled: (name: string) => void = () => {};

  // UI 演示用：模拟选择文件后展示进度
  simulateInstall(): void {
    const fakeName: string = 'demo_app.exe';
    this.progressVisible = true;
    this.progress = 0;

    const timer = setInterval(() => {
      this.progress += 5;
      this.statusText = `正在复制 ${fakeName} 到沙箱 /C/Program Files/... ${this.progress}%`;
      if (this.progress >= 100) {
        clearInterval(timer);
        this.statusText = '复制完成！已添加到应用库。';
        setTimeout(() => {
          this.progressVisible = false;
          this.onInstalled(fakeName.replace('.exe', ''));
        }, 1000);
      }
    }, 50);
  }

  build() {
    Column() {
      Text('安装新应用程序')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 20 })

      Column() {
        Text('📦').fontSize(48).margin({ bottom: 20 })
        Text('将 .exe 或 .msi 文件拖到此处')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 8 })
        Text('Wine 将自动创建沙箱并复制必要文件')
          .fontSize(14)
          .fontColor(Theme.TEXT_SECONDARY)
          .margin({ bottom: 20 })

        Button('选择本地文件')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor(Theme.HM_BLUE)
          .borderRadius(20)
          .padding({ left: 24, right: 24, top: 12, bottom: 12 })
          .onClick(() => {
            this.simulateInstall();
          })

        if (this.progressVisible) {
          Column() {
            Text(this.statusText)
              .fontSize(14)
              .fontColor(Theme.TEXT_SECONDARY)
              .margin({ bottom: 10 })

            Stack({ alignContent: Alignment.Start }) {
              // 背景轨道
              Row()
                .width('100%')
                .height(6)
                .backgroundColor('#EEEEEE')
                .borderRadius(3)
              // 填充
              Row()
                .width(`${this.progress}%`)
                .height(6)
                .backgroundColor(Theme.HM_BLUE)
                .borderRadius(3)
                .animation({ duration: 300, curve: Curve.EaseOut })
            }
            .width('100%')
          }
          .width('100%')
          .margin({ top: 30 })
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .padding(60)
      .backgroundColor(Color.White)
      .borderRadius(Theme.RADIUS)
      .border({
        width: 2,
        color: this.highlight ? Theme.HM_BLUE : '#CCCCCC',
        style: BorderStyle.Dashed
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}