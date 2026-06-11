import { Theme } from '../common/Theme';
import { AppInfo } from '../model/AppInfo';

@Component
export struct LibraryPage {
  @Link apps: AppInfo[];
  onLaunch: (name: string) => void = () => {};

  build() {
    Column() {
      Text('已安装的 Windows 程序')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 20 })

      // 一个外层容器,里面用 if/else 切换内容,避免顶层条件渲染歧义
      Column() {
        if (this.apps.length === 0) {
          Column({ space: 12 }) {
            Text('📭').fontSize(48)
            Text('还没有安装任何应用')
              .fontSize(15)
              .fontColor('#666666')
            Text('前往「安装应用」开始添加')
              .fontSize(12)
              .fontColor('#999999')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          Flex({
            direction: FlexDirection.Row,
            wrap: FlexWrap.Wrap,
            justifyContent: FlexAlign.Start,
            alignItems: ItemAlign.Start
          }) {
            ForEach(this.apps, (app: AppInfo, index: number) => {
              AppCard({ app: app, onLaunch: this.onLaunch })
            }, (app: AppInfo, index: number) => app.id || `${app.name}_${index}`)
          }
          .width('100%')
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
struct AppCard {
  app: AppInfo = new AppInfo();
  onLaunch: (name: string) => void = () => {};
  @State isHovered: boolean = false;

  build() {
    Column() {
      Stack() {
        Text(this.app.icon).fontSize(32)
      }
      .width(64)
      .height(64)
      .backgroundColor('#F0F0F0')
      .borderRadius(14)
      .margin({ bottom: 12 })

      Text(this.app.name)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width(140)
    .height(150)
    .padding({ top: 18, bottom: 18, left: 10, right: 10 })
    .margin({ right: 20, bottom: 20 })
    .backgroundColor(Theme.HM_CARD)
    .borderRadius(Theme.RADIUS)
    .border({
      width: 1,
      color: this.isHovered ? Theme.HM_BLUE : '#00000000'
    })
    .scale({
      x: this.isHovered ? 1.04 : 1,
      y: this.isHovered ? 1.04 : 1
    })
    .shadow(this.isHovered
      ? { radius: 16, color: '#14000000', offsetX: 0, offsetY: 6 }
      : { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
    .animation({ duration: 200, curve: Curve.EaseOut })
    .onHover((isHover: boolean) => {
      this.isHovered = isHover;
    })
    .onClick(() => {
      this.onLaunch(this.app.name);
    })
  }
}