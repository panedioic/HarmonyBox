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
    { id: PageType.LIBRARY,      label: '应用库',       icon: '🏠' },
    { id: PageType.CONTAINER,    label: '容器管理',     icon: '📦' },
    { id: PageType.INSTALL,      label: '安装应用',     icon: '➕' },
    { id: PageType.SETTINGS,     label: '环境设置',     icon: '⚙️' },
    { id: PageType.FILES,        label: '沙箱文件',     icon: '📂' },
    { id: PageType.PROC_MANAGER, label: '进程管理',     icon: '🛡️' },
    { id: PageType.DEBUG_SHELL,  label: '调试终端',     icon: '🐚' },
    { id: PageType.DEBUG,        label: '调试页面(旧)', icon: '🧪' }
  ];

  build() {
    Column() {
      // ── Logo 区 ──
      Row({ space: 10 }) {
        Text('🍷').fontSize(22)
        Column() {
          Text('HarmonyBox')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.TEXT_MAIN)
          Text('v1.0.0')
            .fontSize(11)
            .fontColor(Theme.TEXT_HINT)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 4, bottom: 4 })
      .margin({ bottom: 20 })

      // ── 导航列表 ──
      Column({ space: 4 }) {
        ForEach(this.navItems, (item: NavItem): void => {
          NavItemView({
            item: item,
            currentPage: $currentPage
          })
        }, (item: NavItem): string => item.id)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12 })
      .alignItems(HorizontalAlign.Start)
    }
    .width(208)
    .height('100%')
    .backgroundColor(Theme.HM_CARD)
    .border({ width: { right: 1 }, color: Theme.BORDER_LIGHT })
    .padding({ top: 24, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
struct NavItemView {
  item: NavItem = { id: '', label: '', icon: '' };
  @Link currentPage: string;
  @State isHovered: boolean = false;

  private isSelected(): boolean {
    return this.currentPage === this.item.id;
  }

  private bgColor(): ResourceColor {
    if (this.isSelected()) return Theme.HM_BLUE_SOFT;
    if (this.isHovered)   return '#F5F7FA';
    return Color.Transparent;
  }

  private fgColor(): ResourceColor {
    return this.isSelected() ? Theme.HM_BLUE : Theme.TEXT_SEC;
  }

  build() {
    Row({ space: 10 }) {
      Text(this.item.icon).fontSize(16)
      Text(this.item.label)
        .fontSize(14)
        .fontColor(this.fgColor())
        .layoutWeight(1)
    }
    .width('100%')
    .height(40)
    .padding({ left: 14, right: 14 })
    .borderRadius(10)
    .backgroundColor(this.bgColor())
    .hoverEffect(HoverEffect.None)           // 关掉系统默认 hover 波纹
    .onHover((isHover: boolean): void => {
      if (this.isHovered !== isHover) {      // 去重, 避免重复 render
        this.isHovered = isHover;
      }
    })
    .onClick((): void => {
      this.currentPage = this.item.id;
    })
  }
}