import { Theme, PageType } from '../common/Theme';

interface NavItem {
  id: string;
  label: string;
  icon: string;
}

@Component
export struct BottomNav {
  @Link currentPage: string;
  screenWidth: number = 720;

  private allItems: NavItem[] = [
    { id: PageType.LIBRARY,      label: '应用库', icon: '🏠' },
    { id: PageType.CONTAINER,    label: '容器',   icon: '📦' },
    { id: PageType.SETTINGS,     label: '设置',   icon: '⚙️' },
    { id: PageType.PROC_MANAGER, label: '进程',   icon: '🛡️' },
    { id: PageType.DEBUG_SHELL,  label: '终端',   icon: '🐚' }
  ];

  /** 依次隐藏: 进程管理 -> 调试终端 */
  private visibleItems(): NavItem[] {
    let items: NavItem[] = this.allItems;
    if (this.screenWidth < 500) {
      items = items.filter((x: NavItem): boolean => x.id !== PageType.PROC_MANAGER);
    }
    if (this.screenWidth < 400) {
      items = items.filter((x: NavItem): boolean => x.id !== PageType.DEBUG_SHELL);
    }
    return items;
  }

  build() {
    Row() {
      ForEach(this.visibleItems(), (item: NavItem): void => {
        Column({ space: 3 }) {
          Text(item.icon).fontSize(20)
          Text(item.label)
            .fontSize(10)
            .fontColor(this.currentPage === item.id ? Theme.HM_BLUE : Theme.TEXT_SEC)
            .fontWeight(this.currentPage === item.id
              ? FontWeight.Medium : FontWeight.Regular)
            .maxLines(1)
        }
        .layoutWeight(1)
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.currentPage === item.id
          ? Theme.HM_BLUE_SOFT : Color.Transparent)
        .onClick((): void => {
          this.currentPage = item.id;
        })
      }, (item: NavItem): string => item.id)
    }
    .width('100%')
    .height(58)
    .backgroundColor(Theme.HM_CARD)
    .border({ width: { top: 1 }, color: Theme.BORDER_LIGHT })
  }
}