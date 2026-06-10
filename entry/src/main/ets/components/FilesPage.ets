import { Theme } from '../common/Theme';

@Component
export struct FilesPage {
  private folders: string[] = ['C:\\Program Files', 'C:\\Users', 'C:\\Windows', 'C:\\Temp'];

  build() {
    Column() {
      Text('沙箱文件')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 20 })

      Column() {
        ForEach(this.folders, (path: string) => {
          Row({ space: 12 }) {
            Text('📁').fontSize(20)
            Text(path).fontSize(14)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(12)
          .margin({ bottom: 10 })
        }, (path: string) => path)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}