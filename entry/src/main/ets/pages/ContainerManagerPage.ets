import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { ContainerInfo, ContainerType, containerTypeLabel } from '../model/ContainerInfo';
import { ContainerService, InstallResult } from '../service/ContainerService';
import { InstallContainerDialog } from '../components/InstallContainerDialog';
import { picker } from '@kit.CoreFileKit';
import { EditContainerDialog } from '../components/EditContainerDialog';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HBox_UI_Page_ContainerManager';

@Component
export struct ContainerManagerPage {
  @State containers: ContainerInfo[] = [];
  @State expandedId: string = '';
  @State busy: string = '';   // 正在启停的容器 id
  @State exporting: string = '';
  @State resetting: string = '';

  private editDialog: CustomDialogController | null = null;

  private installDialog: CustomDialogController = new CustomDialogController({
    builder: InstallContainerDialog({
      onInstalled: (info: ContainerInfo): void => {
        this.reload();
      }
    }),
    autoCancel: true,
    customStyle: true,
    alignment: DialogAlignment.Center
  });

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    const ctx = getContext(this) as common.Context;
    this.containers = ContainerService.list(ctx);
  }

  private async doStart(info: ContainerInfo): Promise<void> {
    this.busy = info.id;
    try {
      const ctx = getContext(this) as common.Context;
      const ok: boolean = await ContainerService.start(ctx, info);
      if (ok) {
        info.running = true;
        info.startTime = Date.now();
        this.containers = this.containers.slice();
      }
    } finally {
      this.busy = '';
    }
  }

  private async doStop(info: ContainerInfo): Promise<void> {
    this.busy = info.id;
    try {
      const ctx = getContext(this) as common.Context;
      const ok: boolean = await ContainerService.stop(ctx, info);
      if (ok) {
        info.running = false;
        info.startTime = 0;
        this.containers = this.containers.slice();
      }
    } finally {
      this.busy = '';
    }
  }

  private confirmDelete(info: ContainerInfo): void {
    AlertDialog.show({
      title: '删除容器',
      message: `确定要删除容器「${info.config.name}」吗？\n\n容器目录 ${info.path} 将被清空, 此操作不可撤销。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '删除', fontColor: '#E64545',
        action: (): void => {
          const ctx = getContext(this) as common.Context;
          if (ContainerService.uninstall(ctx, info.id)) this.reload();
        }
      }
    });
  }

  private async doExport(c: ContainerInfo): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const p: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opts.newFileNames = [`${c.id}.tar.zst`];
      const uris: string[] = await p.save(opts);
      if (!uris || uris.length === 0) return;
      this.exporting = c.id;
      const r: InstallResult = await ContainerService.exportContainer(
        ctx as common.Context, c, uris[0]);
      this.exporting = '';
      if (r.ok) {
        AlertDialog.show({
          title: '导出成功',
          message: `容器已导出到:\n${uris[0]}`,
          confirm: { value: '好的', action: (): void => {} },
          alignment: DialogAlignment.Center
        });
      } else {
        AlertDialog.show({
          title: '导出失败',
          message: r.error,
          confirm: { value: '好的', action: (): void => {} },
          alignment: DialogAlignment.Center
        });
      }
    } catch (e) {
      this.exporting = '';
      hilog.error(0x0000, TAG, `export failed: ${(e as Error).message}`);
    }
  }

  private confirmResetPrefix(c: ContainerInfo): void {
    AlertDialog.show({
      title: '重置 Wine Prefix',
      message: `即将删除容器「${c.config.name}」的 wineprefix 并重新初始化。\n\n`
        + `已安装的 Windows 应用注册表、字体安装、winetricks 组件将全部丢失。\n\n`
        + `重新初始化会跑一次 wineboot, 约需 30~120 秒, 是否继续?`,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '确认重置',
        fontColor: '#E64545',
        action: (): void => { this.doResetPrefix(c); }
      },
      alignment: DialogAlignment.Center
    });
  }

  private async doResetPrefix(c: ContainerInfo): Promise<void> {
    this.resetting = c.id;
    const ok: boolean = await ContainerService.initWineContainer(c);
    this.resetting = '';
    this.reload();
    AlertDialog.show({
      title: ok ? '重置完成' : '重置失败',
      message: ok
        ? 'Wine prefix 已重新初始化, 可以启动 Windows 应用了'
        : 'wineboot 未成功完成, 请查看 hilog 排查 (WINEDEBUG=+init,+seh)',
      confirm: { value: '好的', action: (): void => {} },
      alignment: DialogAlignment.Center
    });
  }

  private openEditDialog(c: ContainerInfo): void {
    this.editDialog = new CustomDialogController({
      builder: EditContainerDialog({
        info: c,
        onSaved: (_i: ContainerInfo): void => {
          this.reload();
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    });
    this.editDialog.open();
  }

  build() {
    Column() {
      // header
      Row() {
        Column() {
          Text('容器管理')
            .fontSize(24).fontWeight(FontWeight.Bold)
            .fontColor(Theme.TEXT_MAIN)
          Text('管理你的 Wine / Linux 容器环境')
            .fontSize(12).fontColor(Theme.TEXT_HINT)
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)

        Button() {
          Row({ space: 6 }) {
            Text('+').fontSize(16).fontColor(Color.White)
            Text('创建容器').fontSize(13).fontColor(Color.White)
          }
        }
        .height(36).padding({ left: 14, right: 14 })
        .backgroundColor(Theme.HM_BLUE).borderRadius(8)
        .onClick((): void => { this.installDialog.open(); })
      }
      .width('100%').margin({ bottom: 20 })

      // list
      if (this.containers.length === 0) {
        Column({ space: 12 }) {
          Text('📦').fontSize(48)
          Text('还没有任何容器').fontSize(15).fontColor(Theme.TEXT_SEC)
          Text('点击右上角「创建容器」开始').fontSize(12).fontColor(Theme.TEXT_HINT)
        }
        .width('100%').layoutWeight(1)
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Scroll() {
          Column({ space: 12 }) {
            ForEach(this.containers, (c: ContainerInfo): void => {
              this.Card(c)
            }, (c: ContainerInfo): string => c.id)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1).width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%').height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  Card(c: ContainerInfo) {
    Column() {
      // 顶部摘要行
      Row({ space: 14 }) {
        // icon
        Column() {
          Text(c.config.type === 'wine' ? '🍷' : '🐧')
            .fontSize(28)
        }
        .width(52).height(52)
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        .backgroundColor('#F5F7FA').borderRadius(10)

        // 信息
        Column({ space: 4 }) {
          Row({ space: 8 }) {
            Text(c.config.name).fontSize(15).fontColor(Theme.TEXT_MAIN)
              .fontWeight(FontWeight.Medium)
            Text(containerTypeLabel(c.config.type))
              .fontSize(10).fontColor(Theme.HM_BLUE)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(Theme.HM_BLUE_SOFT).borderRadius(4)
            if (c.config.version) {
              Text(c.config.version).fontSize(10).fontColor(Theme.TEXT_HINT)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor('#F0F0F0').borderRadius(4)
            }
            Text(c.config.arch).fontSize(10).fontColor(Theme.TEXT_HINT)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor('#F0F0F0').borderRadius(4)
            Row({ space: 4 }) {
              Circle().width(6).height(6)
                .fill(c.running ? '#5DD46E' : '#B0B7C0')
              Text(c.running ? '运行中' : '未运行')
                .fontSize(11).fontColor(c.running ? '#5DD46E' : Theme.TEXT_HINT)
            }
          }
          Text(c.path).fontSize(11).fontColor(Theme.TEXT_HINT)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)

        // 操作按钮组
        Row({ space: 8 }) {
          if (!c.running) {
            Button('启动').fontSize(12).height(32).width(64)
              .backgroundColor(Theme.HM_BLUE)
              .enabled(this.busy !== c.id)
              .onClick((): void => { this.doStart(c); })
          } else {
            Button('停止').fontSize(12).height(32).width(64)
              .backgroundColor('#F0F0F0').fontColor(Theme.TEXT_MAIN)
              .enabled(this.busy !== c.id)
              .onClick((): void => { this.doStop(c); })
          }
          Text(this.expandedId === c.id ? '▲' : '▼')
            .fontSize(12).fontColor(Theme.TEXT_HINT)
            .padding(8).borderRadius(6)
            .onClick((): void => {
              this.expandedId = this.expandedId === c.id ? '' : c.id;
            })
        }
      }
      .width('100%').padding(16)

      // 展开区
      if (this.expandedId === c.id) {
        Divider().color(Theme.BORDER_LIGHT)
        this.DetailPanel(c)
      }
    }
    .width('100%')
    .backgroundColor(Theme.HM_CARD)
    .borderRadius(Theme.RADIUS)
    .border({ width: 1, color: Theme.BORDER_LIGHT })
  }

  @Builder
  DetailPanel(c: ContainerInfo) {
    Column({ space: 14 }) {
      // 基本信息
      Column({ space: 8 }) {
        this.DetailRowLabel('基本信息')
        Row() {
          this.DetailKV('ID', c.id)
          this.DetailKV('类型', containerTypeLabel(c.config.type))
          this.DetailKV('架构', c.config.arch)
          this.DetailKV('版本', c.config.version || '-')
        }.width('100%')
        Row() {
          this.DetailKV('创建时间',
            c.config.createdAt > 0
              ? new Date(c.config.createdAt).toLocaleString()
              : '-')
          this.DetailKV('状态', c.running ? '运行中' : '已停止')
          this.DetailKV('PID', c.pid > 0 ? String(c.pid) : '-')
          this.DetailKV('启动时间',
            c.startTime > 0
              ? new Date(c.startTime).toLocaleTimeString()
              : '-')
        }.width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)

      // 描述
      if (c.config.description) {
        Column({ space: 6 }) {
          this.DetailRowLabel('描述')
          Text(c.config.description)
            .fontSize(12).fontColor(Theme.TEXT_MAIN)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }

      // 环境变量
      Column({ space: 6 }) {
        this.DetailRowLabel('环境变量')
        if (!c.config.envVars || c.config.envVars.length === 0) {
          Text('(无)').fontSize(12).fontColor(Theme.TEXT_HINT)
        } else {
          ForEach(c.config.envVars, (kv: string): void => {
            Text(kv)
              .fontSize(11).fontColor(Theme.TEXT_MAIN)
              .fontFamily('monospace')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }, (kv: string, idx: number): string => `${idx}:${kv}`)
        }
      }.width('100%').alignItems(HorizontalAlign.Start)

      // 底部操作
      Row({ space: 10 }) {
        Button('编辑')
          .fontSize(12).height(32)
          .backgroundColor('#F0F0F0').fontColor(Theme.TEXT_MAIN)
          .onClick((): void => { this.openEditDialog(c); })

        if (c.config.type === ContainerType.WINE) {
          Button(this.resetting === c.id ? '重置中...' : '重置 prefix')
            .fontSize(12).height(32)
            .backgroundColor('#FFF4E5').fontColor('#B76E00')
            .enabled(this.resetting !== c.id)
            .onClick((): void => { this.confirmResetPrefix(c); })
        }
        if (ContainerService.hasFonts(c.path)) {
          Button('重生字体配置')
            .fontSize(12).height(32)
            .backgroundColor('#F0F0F0').fontColor(Theme.TEXT_MAIN)
            .onClick((): void => {
              const ok: boolean = ContainerService.regenerateFontConfig(c);
              this.reload();
              AlertDialog.show({
                title: ok ? '重生成功' : '重生失败',
                message: ok
                  ? '字体配置已重新生成, 环境变量已更新'
                  : '容器目录中未检测到字体文件',
                confirm: { value: '好的', action: (): void => {} },
                alignment: DialogAlignment.Center
              });
            })
        }
        Blank()
        Button(this.exporting === c.id ? '导出中...' : '导出为 tar')
          .fontSize(12).height(32)
          .backgroundColor('#F0F0F0').fontColor(Theme.TEXT_MAIN)
          .enabled(this.exporting !== c.id)
          .onClick((): void => { this.doExport(c); })
        Button('删除容器')
          .fontSize(12).height(32)
          .backgroundColor('#FEE4E4').fontColor('#E64545')
          .onClick((): void => { this.confirmDelete(c); })
      }.width('100%')
    }
    .width('100%').padding(16)
    .backgroundColor('#FAFBFC').alignItems(HorizontalAlign.Start)
  }

  @Builder
  DetailRowLabel(t: string) {
    Text(t).fontSize(11).fontColor(Theme.TEXT_HINT)
      .fontWeight(FontWeight.Medium)
  }

  @Builder
  DetailKV(k: string, v: string) {
    Column({ space: 3 }) {
      Text(k).fontSize(10).fontColor(Theme.TEXT_HINT)
      Text(v).fontSize(12).fontColor(Theme.TEXT_MAIN)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1).alignItems(HorizontalAlign.Start)
    .padding({ right: 12 })
  }
}