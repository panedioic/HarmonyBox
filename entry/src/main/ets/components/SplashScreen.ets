import { Theme } from '../common/Theme';

@Component
export struct SplashScreen {
  appName: string = '';
  onClose: () => void = () => {};
  @State pulseOpacity: number = 0.3;

  aboutToAppear(): void {
    // 简单的呼吸动画循环
    this.startPulse();
  }

  startPulse(): void {
    animateTo({
      duration: 1000,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, () => {
      this.pulseOpacity = 1.0;
    });
  }

  build() {
    Column() {
      Text('🍷').fontSize(60).margin({ bottom: 20 })
      Text(`正在启动 ${this.appName}...`)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .margin({ bottom: 12 })
      Text('正在初始化 Wine 容器并挂载驱动器...')
        .fontSize(14)
        .fontColor('rgba(255,255,255,0.8)')

      // 进度条
      Stack() {
        Row().width('100%').height(4).backgroundColor('#333333')
        Row()
          .width('100%')
          .height(4)
          .backgroundColor(Theme.HM_BLUE)
          .opacity(this.pulseOpacity)
      }
      .width(200)
      .margin({ top: 20 })

      Button('退出运行')
        .fontSize(14)
        .fontColor(Color.White)
        .backgroundColor('#444444')
        .borderRadius(20)
        .padding({ left: 24, right: 24, top: 12, bottom: 12 })
        .margin({ top: 40 })
        .onClick(() => {
          this.onClose();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(0,0,0,0.8)')
  }
}