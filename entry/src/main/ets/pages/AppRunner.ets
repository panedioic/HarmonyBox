@Entry
@Component
struct AppRunner {
  @State appName: string = '应用';
  @State isLoading: boolean = true;
  private xController: XComponentController = new XComponentController();
  private loadTimer: number = -1;

  aboutToAppear(): void {
    // 从 AppStorage 取启动应用名（主窗口在创建子窗口前已写入）
    const name = AppStorage.get<string>('currentAppName');
    if (name) {
      this.appName = name;
    }

    // 模拟 Wine 容器初始化
    this.loadTimer = setTimeout(() => {
      this.isLoading = false;
    }, 2000);
  }

  aboutToDisappear(): void {
    if (this.loadTimer !== -1) {
      clearTimeout(this.loadTimer);
    }
  }

  build() {
    Stack() {
      // 底层：XComponent surface（加载阶段隐藏）
      XComponent({
        id: 'appSurface',
        type: XComponentType.SURFACE,
        controller: this.xController
      })
        .width('100%')
        .height('100%')
        .onLoad(() => {
          console.info('AppRunner XComponent loaded');
        })
        .visibility(this.isLoading ? Visibility.Hidden : Visibility.Visible)

      // 加载完成后：模拟应用窗口内容
      if (!this.isLoading) {
        Column() {
          // 模拟应用标题栏
          Row() {
            Text('🪟').fontSize(14).margin({ right: 8 })
            Text(this.appName)
              .fontSize(13)
              .fontColor(Color.White)
              .layoutWeight(1)
            Text('— ☐ ✕')
              .fontSize(12)
              .fontColor(Color.White)
          }
          .width('100%')
          .height(32)
          .padding({ left: 12, right: 12 })
          .backgroundColor('#0078D4')

          // 模拟应用内容
          Scroll() {
            Column({ space: 16 }) {
              Text(`欢迎使用 ${this.appName}`)
                .fontSize(22)
                .fontWeight(FontWeight.Bold)

              Text('这是运行在 Wine 容器中的 Windows 应用模拟界面。\n后续将通过 XComponent surface 接入真实渲染。')
                .fontSize(14)
                .fontColor('#666666')
                .lineHeight(22)

              Divider().strokeWidth(1).color('#EEEEEE')

              Text('示例控件:')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)

              Row({ space: 12 }) {
                Button('确定')
                  .fontSize(13)
                  .backgroundColor('#0078D4')
                  .height(32)
                Button('取消')
                  .fontSize(13)
                  .fontColor('#333333')
                  .backgroundColor('#E1E1E1')
                  .height(32)
              }

              Row({ space: 12 }) {
                Text('文件路径:').fontSize(14)
                TextInput({ placeholder: 'C:\\Program Files\\...' })
                  .layoutWeight(1)
                  .height(32)
                  .fontSize(13)
              }

              Text(`PID: ${Math.floor(Math.random() * 9000 + 1000)}    内存占用: 128 MB`)
                .fontSize(12)
                .fontColor('#999999')
                .margin({ top: 8 })
            }
            .padding(24)
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
          .layoutWeight(1)
          .width('100%')
          .backgroundColor('#FFFFFF')
        }
        .width('100%')
        .height('100%')
      }

      // 加载占位层
      if (this.isLoading) {
        Column({ space: 16 }) {
          Text('🍷').fontSize(64)
          Text(`正在启动 ${this.appName}`)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
          Text('正在初始化 Wine 容器并挂载驱动器...')
            .fontSize(13)
            .fontColor('#BBBBBB')
          LoadingProgress()
            .width(36)
            .height(36)
            .color('#007DFF')
            .margin({ top: 12 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#1A1A1A')
      }
    }
    .width('100%')
    .height('100%')
  }
}