@Entry
@Component
struct AppRunner {
  @State appName: string = '应用';

  aboutToAppear(): void {
    const name = AppStorage.get<string>('currentAppName');
    if (name) {
      this.appName = name;
    }
  }

  build() {
    Stack() {
      XComponent({
        id: 'wl_xc',
        type: XComponentType.SURFACE,
        libraryname: 'entry'
      })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }
}