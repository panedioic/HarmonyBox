import { Theme } from '../common/Theme';
import { AppInfo } from '../model/AppInfo';
import { EditAppDialog } from './EditAppDialog';
import { InstallAppDialog } from './InstallAppDialog';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HBox_UI_Comp_Library';

// LibraryPage 顶层增加 onEdit / onExport / onUpdate 三个回调透传
@Component
export struct LibraryPage {
  @Link apps: AppInfo[];
  @Prop runningIds: string[] = [];
  onLaunch: (app: AppInfo) => void = () => {};
  onLaunchWithLog: (app: AppInfo) => void = () => {};
  onDelete: (app: AppInfo) => void = () => {};
  onEdit: (app: AppInfo) => void = () => {};
  onExport: (app: AppInfo) => void = () => {};
  onUpdate: (app: AppInfo) => void = () => {};
  onCreateShortcut: (app: AppInfo) => void = () => {};
  onInstalled: (app: AppInfo) => void = () => {};
  private installDialog: CustomDialogController = new CustomDialogController({
    builder: InstallAppDialog({
      onInstalled: (app: AppInfo): void => {
        this.onInstalled(app);
      }
    }),
    autoCancel: true,
    customStyle: true,
    alignment: DialogAlignment.Center
  });

  build() {
    Column() {
      // ── Header: 标题 + 描述 + 安装按钮 ──
      Row() {
        Column() {
          Text('应用库')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.TEXT_MAIN)
          Text('管理和启动你安装的应用程序')
            .fontSize(12)
            .fontColor(Theme.TEXT_HINT)
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button() {
          Row({ space: 6 }) {
            Text('+').fontSize(16).fontColor(Color.White)
            Text('安装应用').fontSize(13).fontColor(Color.White)
          }
        }
        .height(36)
        .padding({ left: 14, right: 14 })
        .backgroundColor(Theme.HM_BLUE)
        .borderRadius(8)
        .onClick((): void => { this.installDialog.open(); })
      }
      .width('100%')
      .margin({ bottom: 20 })

      // ── 应用网格 (原有 Column 不变) ──
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
            ForEach(this.apps, (app: AppInfo, index: number): void => {
              AppCard({
                app: app,
                isRunning: this.runningIds.includes(app.id),
                onLaunch: this.onLaunch,
                onLaunchWithLog: this.onLaunchWithLog,
                onDelete: this.onDelete,
                onEdit: this.onEdit,
                onExport: this.onExport,
                onUpdate: this.onUpdate,
                onCreateShortcut:  this.onCreateShortcut
              })
            }, (app: AppInfo, index: number): string =>
            app.id || `${app.name}_${index}`)
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
  onLaunch: (app: AppInfo) => void = () => {};
  onLaunchWithLog: (app: AppInfo) => void = () => {};
  onDelete: (app: AppInfo) => void = () => {};
  onEdit: (app: AppInfo) => void = () => {};
  onExport: (app: AppInfo) => void = () => {};
  onUpdate: (app: AppInfo) => void = () => {};
  onCreateShortcut: (app: AppInfo) => void = () => {};
  @State isHovered: boolean = false;
  @Prop isRunning: boolean = false;

  // dialog 控制器在 build 上下文里创建,把 app 和 onSave 直接绑过去
  private editDialog: CustomDialogController = new CustomDialogController({
    builder: EditAppDialog({
      app: this.app,
      onSave: (updated: AppInfo): void => {
        this.onEdit(updated);
      }
    }),
    autoCancel: true,
    customStyle: true,
    alignment: DialogAlignment.Center
  });

  @Builder
  ContextMenu() {
    Menu() {
      MenuItem({ content: '启动应用' })
        .onClick((): void => { this.onLaunch(this.app); })

      MenuItem({ content: '启动并显示日志' })
        .onClick((): void => { this.onLaunchWithLog(this.app); })

      MenuItem({ content: '添加到桌面' })
        .onClick((): void => { this.onCreateShortcut(this.app); })

      MenuItem({ content: '编辑信息' })
        .onClick((): void => { this.editDialog.open(); })

      MenuItem({ content: '更新应用' })
        .onClick((): void => { this.onUpdate(this.app); })

      MenuItem({ content: '导出应用' })
        .onClick((): void => { this.onExport(this.app); })

      MenuItem({ content: '查看路径' })
        .onClick((): void => { hilog.info(0x0000, TAG,`installDir: ${this.app.installDir}`); })

      MenuItem({ content: '删除应用' })
        .onClick((): void => { this.confirmDelete(); })
    }
  }

  confirmDelete(): void {
    AlertDialog.show({
      title: '删除应用',
      message: `确定要删除「${this.app.name}」吗?\n\n应用目录及其全部文件都会被移除,此操作无法撤销。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E64545',
        action: (): void => {
          this.onDelete(this.app);
        }
      }
    });
  }

  build() {
    Column() {
      Stack() {
        Stack() {
          Text(this.app.icon).fontSize(32)
        }
        .width(64).height(64)
        .backgroundColor('#F0F0F0')
        .borderRadius(14)

        if (this.isRunning) {
          Circle()
            .width(12).height(12)
            .fill('#5DD46E')
            .stroke('#FFFFFF')
            .strokeWidth(2)
            .offset({ x: 26, y: -26 })
        }
      }
      .margin({ bottom: 12 })

      Row({ space: 4 }) {
        if (this.isRunning) {
          Text('●')
            .fontSize(9)
            .fontColor('#5DD46E')
        }
        Text(this.app.name)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .maxLines(2)
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
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
    .onHover((isHover: boolean): void => {
      this.isHovered = isHover;
    })
    .onClick((): void => {
      this.onLaunch(this.app);
    })
    .bindContextMenu(this.ContextMenu, ResponseType.RightClick)
  }
}