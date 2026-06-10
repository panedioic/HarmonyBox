import { Theme, PageType } from '../common/Theme';

interface NavItem {
  id: string;
  label: string;
  icon: string;
}

@Component
export struct Sidebar {
  @Link currentPage: string;

  private navItems: NavItem[] = [
    { id: PageType.LIBRARY, label: '应用库', icon: '🏠' },
    { id: PageType.INSTALL, label: '安装应用', icon: '➕' },
    { id: PageType.SETTINGS, label: '环境设置', icon: '⚙️' },
    { id: PageType.FILES, label: '沙箱文件', icon: '📂' }
  ];

  @Builder
  NavItemView(item: NavItem) {
    Row({ space: 12 }) {
      Text(item.icon).fontSize(16)
      Text(item.label).fontSize(14)
    }
    .width('100%')
    .padding({ left: 25, right: 25, top: 12, bottom: 12 })
    .margin({ left: 12, right: 12, top: 4, bottom: 4 })
    .borderRadius(Theme.RADIUS_NAV)
    .backgroundColor(this.currentPage === item.id ? Theme.HM_BLUE : Color.Transparent)
    .shadow(this.currentPage === item.id
      ? { radius: 12, color: 'rgba(0,125,255,0.3)', offsetY: 4 }
      : { radius: 0, color: Color.Transparent })
    .onClick(() => {
      this.currentPage = item.id;
    })
    .animation({ duration: 300, curve: Curve.EaseOut })
  }

  build() {
    Column() {
      // Logo
      Row({ space: 10 }) {
        Text('🍷').fontSize(22)
        Text('HarmonyBox')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.HM_BLUE)
      }
      .width('100%')
      .padding({ left: 25, right: 25, bottom: 30 })

      // 导航组
      Column() {
        ForEach(this.navItems, (item: NavItem) => {
          Row({ space: 12 }) {
            Text(item.icon).fontSize(16)
            Text(item.label)
              .fontSize(14)
              .fontColor(this.currentPage === item.id ? Color.White : Theme.TEXT_SECONDARY)
          }
          .width('100%')
          .padding({ left: 25, right: 25, top: 12, bottom: 12 })
          .margin({ left: 12, right: 12, top: 4, bottom: 4 })
          .borderRadius(Theme.RADIUS_NAV)
          .backgroundColor(this.currentPage === item.id ? Theme.HM_BLUE : Color.Transparent)
          .onClick(() => {
            this.currentPage = item.id;
          })
        }, (item: NavItem) => item.id)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 底部版本号
      Text('Wine 9.0 (HarmonyOS Edition)')
        .fontSize(12)
        .fontColor(Theme.TEXT_HINT)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding(20)
    }
    .width(Theme.SIDEBAR_WIDTH)
    .height('100%')
    .backgroundColor('rgba(255,255,255,0.8)')
    .backdropBlur(20)
    .border({ width: { right: 1 }, color: Theme.BORDER_LIGHT })
    .padding({ top: 20, bottom: 20 })
  }
}