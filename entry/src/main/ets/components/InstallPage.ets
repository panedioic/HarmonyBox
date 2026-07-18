import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import {
  AppInfo, AppType, RuntimeMode,
  runtimeModeLabel, AppConfig
} from '../model/AppInfo';
import { InstallService } from '../service/InstallService';
import { ContainerService } from '../service/ContainerService';
import { ContainerInfo, ContainerType } from '../model/ContainerInfo';

@Component
export struct InstallPage {
  @State containers: ContainerInfo[] = [];
  @State selectedContainerId: string = '';
  @State runtimeMode: RuntimeMode = RuntimeMode.GUI;
  @State sourceFolderUri: string = '';
  @State sourceFolderName: string = '';
  @State execRelPath: string = '';
  @State appName: string = '';
  @State appIcon: string = '📦';
  @State envVars: string = '';
  @State launchArgs: string = '';
  @State installing: boolean = false;
  @State progress: number = 0;
  @State statusText: string = '';

  onInstalled: (app: AppInfo) => void = (): void => {};

  private allModes: RuntimeMode[] = [RuntimeMode.GUI, RuntimeMode.CLI];

  aboutToAppear(): void {
    this.reloadContainers();
  }

  private reloadContainers(): void {
    const ctx = getContext(this) as common.Context;
    this.containers = ContainerService.list(ctx);
    if (this.containers.length > 0
      && !this.containers.some((c: ContainerInfo): boolean =>
      c.id === this.selectedContainerId)) {
      this.selectedContainerId = this.containers[0].id;
    }
  }

  private getSelectedContainer(): ContainerInfo | null {
    for (const c of this.containers) {
      if (c.id === this.selectedContainerId) return c;
    }
    return null;
  }

  private deriveAppType(c: ContainerInfo): AppType {
    if (c.config.type === ContainerType.WINE) return AppType.WINDOWS;
    return AppType.LINUX;
  }

  async chooseFolder(): Promise<void> {
    const uri: string | null = await InstallService.pickFolder();
    if (uri) {
      this.sourceFolderUri = uri;
      this.sourceFolderName = InstallService.folderNameFromUri(uri);
      if (!this.appName) this.appName = this.sourceFolderName;
    }
  }

  async chooseExecFile(): Promise<void> {
    if (!this.sourceFolderUri) {
      this.statusText = '请先选择应用文件夹';
      return;
    }
    const fileUri: string | null = await InstallService.pickFile();
    if (!fileUri) return;
    const rel: string | null =
      InstallService.relativePath(this.sourceFolderUri, fileUri);
    if (rel === null) {
      this.statusText = '主程序必须位于已选文件夹内, 请重新选择';
      return;
    }
    this.execRelPath = rel;
    this.statusText = '';
  }

  /** @deprecated InstallPage 不再使用 */
  async startInstall(): Promise<void> {
    const msg: string = '安装方法已废弃';
    this.statusText = `安装失败: ${msg}`;
    this.installing = false;
  }

  resetForm(): void {
    this.installing = false;
    this.progress = 0;
    this.statusText = '';
    this.sourceFolderUri = '';
    this.sourceFolderName = '';
    this.execRelPath = '';
    this.appName = '';
    this.appIcon = '📦';
    this.envVars = '';
    this.launchArgs = '';
    this.runtimeMode = RuntimeMode.GUI;
  }

  @Builder
  ContainerCard(c: ContainerInfo) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(c.config.type === ContainerType.WINE ? '🍷' : '🐧').fontSize(14)
        Text(c.config.name)
          .fontSize(13)
          .fontColor(this.selectedContainerId === c.id ? Color.White : '#333333')
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Text(c.config.description || c.id)
        .fontSize(11)
        .fontColor(this.selectedContainerId === c.id ? '#E0E9F5' : '#999999')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(180).padding(10)
    .borderRadius(8)
    .backgroundColor(this.selectedContainerId === c.id ? Theme.HM_BLUE : '#F0F0F0')
    .margin({ right: 10, bottom: 10 })
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => { this.selectedContainerId = c.id; })
  }

  @Builder
  ModeChip(mode: RuntimeMode) {
    Text(runtimeModeLabel(mode))
      .fontSize(13)
      .fontColor(this.runtimeMode === mode ? Color.White : '#333333')
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.runtimeMode === mode ? Theme.HM_BLUE : '#F0F0F0')
      .borderRadius(8)
      .margin({ right: 10 })
      .onClick((): void => { this.runtimeMode = mode; })
  }

  @Builder
  SectionLabel(title: string) {
    Text(title).fontSize(13).fontWeight(FontWeight.Medium)
      .fontColor('#666666').margin({ top: 14, bottom: 10 })
  }

  build() {
    Scroll() {
      Column() {
        Text('安装新应用程序')
          .fontSize(24).fontWeight(FontWeight.Bold).margin({ bottom: 16 })

        Column() {
          // —— 运行容器 ——
          this.SectionLabel('运行容器')
          if (this.containers.length === 0) {
            Column({ space: 8 }) {
              Text('尚未安装任何容器').fontSize(13).fontColor('#E64545')
              Text('请先到「容器管理」中安装 Linux 或 Wine 容器')
                .fontSize(11).fontColor('#999999')
            }
            .width('100%').padding(14)
            .backgroundColor('#FEF2F2').borderRadius(8)
            .alignItems(HorizontalAlign.Start)
          } else {
            Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
              ForEach(this.containers, (c: ContainerInfo): void => {
                this.ContainerCard(c)
              }, (c: ContainerInfo): string => c.id)
            }
            .width('100%')
            Text('应用类型将由所选容器决定')
              .fontSize(11).fontColor('#999999')
          }

          Divider().color('#EEEEEE').margin({ top: 14 })

          // —— 运行模式 ——
          this.SectionLabel('运行模式')
          Row() {
            ForEach(this.allModes, (m: RuntimeMode): void => {
              this.ModeChip(m)
            }, (m: RuntimeMode): string => m)
          }
          .width('100%')

          Divider().color('#EEEEEE').margin({ top: 14 })

          // —— 应用文件夹 ——
          this.SectionLabel('应用文件夹')
          Row({ space: 12 }) {
            Button('选择文件夹').fontSize(13).height(36)
              .backgroundColor(Theme.HM_BLUE)
              .onClick((): void => { this.chooseFolder(); })
            Text(this.sourceFolderName || '尚未选择')
              .fontSize(13).layoutWeight(1)
              .fontColor(this.sourceFolderName ? '#333333' : '#999999')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%')

          Divider().color('#EEEEEE').margin({ top: 14 })

          // —— 主可执行文件 ——
          this.SectionLabel('主可执行文件 (相对路径)')
          Row({ space: 8 }) {
            TextInput({ placeholder: 'bin/app 或 main.exe', text: this.execRelPath })
              .layoutWeight(1).height(36).fontSize(13)
              .onChange((v: string): void => { this.execRelPath = v; })
            Button('浏览...').fontSize(13).height(36)
              .backgroundColor('#F0F0F0').fontColor('#333333')
              .onClick((): void => { this.chooseExecFile(); })
          }.width('100%')

          Divider().color('#EEEEEE').margin({ top: 14 })

          this.SectionLabel('应用名称')
          TextInput({ placeholder: '显示名称', text: this.appName })
            .height(36).fontSize(13)
            .onChange((v: string): void => { this.appName = v; })

          this.SectionLabel('应用图标 (Emoji)')
          TextInput({ placeholder: '📦', text: this.appIcon })
            .height(36).width(120).fontSize(16)
            .onChange((v: string): void => { this.appIcon = v; })

          Divider().color('#EEEEEE').margin({ top: 14 })

          this.SectionLabel('环境变量')
          TextArea({
            placeholder: 'KEY=VALUE, 可多行或用 ; 分隔\n可用: ${X64_LIBS}, ${FILES_DIR}',
            text: this.envVars
          })
            .height(80).fontSize(13)
            .onChange((v: string): void => { this.envVars = v; })

          this.SectionLabel('启动参数')
          TextInput({ placeholder: '--debug --port=8080', text: this.launchArgs })
            .height(36).fontSize(13)
            .onChange((v: string): void => { this.launchArgs = v; })
        }
        .padding(20).backgroundColor(Color.White).borderRadius(Theme.RADIUS)
        .alignItems(HorizontalAlign.Start).width('100%')

        Column({ space: 12 }) {
          Button(this.installing ? '安装中...' : '开始安装')
            .width('100%').height(44).fontSize(15).fontWeight(FontWeight.Medium)
            .backgroundColor(this.installing || this.containers.length === 0
              ? '#AAAAAA' : Theme.HM_BLUE)
            .enabled(!this.installing && this.containers.length > 0)
            .onClick((): void => { this.startInstall(); })

          if (this.installing || this.statusText) {
            Text(this.statusText).fontSize(13)
              .fontColor(this.statusText.startsWith('安装失败')
                || this.statusText.startsWith('请') ? '#E64545' : '#666666')
          }
          if (this.installing) {
            Stack({ alignContent: Alignment.Start }) {
              Row().width('100%').height(6).backgroundColor('#EEEEEE').borderRadius(3)
              Row().width(`${this.progress}%`).height(6)
                .backgroundColor(Theme.HM_BLUE).borderRadius(3)
                .animation({ duration: 250, curve: Curve.EaseOut })
            }.width('100%')
          }
        }.margin({ top: 20 }).width('100%').alignItems(HorizontalAlign.Start)
      }
      .alignItems(HorizontalAlign.Start).width('100%')
    }
    .width('100%').layoutWeight(1).align(Alignment.Top)
  }
}