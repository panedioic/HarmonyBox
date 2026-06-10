import { Theme } from '../common/Theme';
import { AppInfo } from '../model/AppInfo';

@Component
export struct LibraryPage {
  @Link apps: AppInfo[];
  onLaunch: (name: string) => void = () => {};

  build() {
    Column() {
      Text('已安装的 Windows 程序')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 20 })

      Grid() {
        ForEach(this.apps, (app: AppInfo) => {
          GridItem() {
            this.AppCard(app)
          }
        }, (app: AppInfo, index: number) => `${app.name}_${index}`)
      }
      .columnsTemplate('repeat(auto-fill, 140px)')
      .columnsGap(25)
      .rowsGap(25)
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  AppCard(app: AppInfo) {
    Column() {
      // 图标
      Stack() {
        Text(app.icon).fontSize(30)
      }
      .width(64)
      .height(64)
      .backgroundColor('#F0F0F0')
      .borderRadius(14)
      .margin({ bottom: 12 })

      Text(app.name)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(120)
    .padding(20)
    .backgroundColor(Theme.HM_CARD)
    .borderRadius(Theme.RADIUS)
    .border({ width: 1, color: Color.Transparent })
    .onClick(() => {
      this.onLaunch(app.name);
    })
  }
}