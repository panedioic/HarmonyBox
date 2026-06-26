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
    { id: PageType.FILES, label: '沙箱文件', icon: '📂' },
    { id: PageType.PROC_MANAGER, label: '进程管理', icon: '🛡️' },
    { id: PageType.DEBUG, label: '测试页面', icon: '🔧' }
  ];

  build() {
    Column() {
      // Logo
      Row() {
        Text('🍷').fontSize(20).margin({ right: 8 })
        Text('HarmonyBox')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.HM_BLUE)
      }
      .width('100%')
      .padding({ left: 20, right: 20 })
      .justifyContent(FlexAlign.Start)
      .margin({ bottom: 24 })

      // 导航列表（顶部对齐，向下排列）
      Column() {
        ForEach(this.navItems, (item: NavItem) => {
          NavItemView({
            item: item,
            currentPage: $currentPage
          })
        }, (item: NavItem) => item.id)
      }
      .layoutWeight(1)
      .width('80%')
      .alignItems(HorizontalAlign.Start)

      // // 底部版本号
      // Text('Wine 9.0 (HarmonyOS Edition)')
      //   .fontSize(11)
      //   .fontColor(Theme.TEXT_HINT)
      //   .width('100%')
      //   .textAlign(TextAlign.Center)
      //   .padding({ top: 12, bottom: 12 })
    }
    .width(220)
    .height('100%')
    .backgroundColor('#FAFAFA')
    .border({ width: { right: 1 }, color: Theme.BORDER_LIGHT })
    .padding({ top: 20, bottom: 8 })
  }
}

@Component
struct NavItemView {
  item: NavItem = { id: '', label: '', icon: '' };
  @Link currentPage: string;
  @State isHovered: boolean = false;

  build() {
    Row() {
      Text(this.item.icon).fontSize(15).margin({ right: 10 })
      Text(this.item.label)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.currentPage === this.item.id ? Color.White : '#666666')
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
    .margin({ left: 10, right: 10, top: 3, bottom: 3 })
    .borderRadius(10)
    .backgroundColor(
      this.currentPage === this.item.id
        ? Theme.HM_BLUE
        : (this.isHovered ? '#1A007DFF' : '#00000000')
    )
    .animation({ duration: 200, curve: Curve.EaseOut })
    .onHover((isHover: boolean) => {
      this.isHovered = isHover;
    })
    .onClick(() => {
      this.currentPage = this.item.id;
    })
  }
}