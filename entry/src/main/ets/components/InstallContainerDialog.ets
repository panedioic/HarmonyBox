import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { Theme } from '../common/Theme';
import { ContainerType, containerTypeLabel, ContainerInfo } from '../model/ContainerInfo';
import { BuiltinEntry, ContainerService, InstallOptions, InstallResult } from '../service/ContainerService';

interface SourceOption {
  id: 'tar' | 'folder' | 'network' | 'builtin';
  label: string;
  icon: string;
  enabled: boolean;
}

interface BuiltinItem {
  id: string;
  name: string;
  desc: string;
}

@CustomDialog
export struct InstallContainerDialog {
  controller?: CustomDialogController;
  onInstalled: (info: ContainerInfo) => void = () => {};

  @State currentSource: string = 'tar';
  @State archiveUri:  string = '';
  @State archiveName: string = '';
  @State folderUri:   string = '';
  @State folderName:  string = '';

  @State cName:        string = '';
  @State cDescription: string = '';
  @State cType:        ContainerType = ContainerType.WINE;

  @State installing: boolean = false;
  @State status:     string = '';

  private sources: SourceOption[] = [
    { id: 'tar',     label: '本地 tar 包',   icon: '📦', enabled: true  },
    { id: 'folder',  label: '本地文件夹',    icon: '📁', enabled: true  },
    { id: 'network', label: '从网络安装',    icon: '🌐', enabled: false },
    { id: 'builtin', label: '内置容器',      icon: '⭐', enabled: true }
  ];

  private types: ContainerType[] = [ContainerType.WINE, ContainerType.LINUX];

  private builtins: BuiltinEntry[] = ContainerService.getBuiltins();

  // ──────────────────────────────────────────────
  private async chooseTar(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const p = new picker.DocumentViewPicker(ctx);
      const opts = new picker.DocumentSelectOptions();
      opts.selectMode = picker.DocumentSelectMode.FILE;
      opts.fileSuffixFilters = ['.tar'];
      const uris: string[] = await p.select(opts);
      if (uris && uris.length > 0) {
        this.archiveUri = uris[0];
        const idx: number = this.archiveUri.lastIndexOf('/');
        this.archiveName = idx >= 0
          ? this.archiveUri.substring(idx + 1)
          : this.archiveUri;
      }
    } catch (e) {
      this.status = '选择文件失败: ' + (e as Error).message;
    }
  }

  private async chooseFolder(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const p = new picker.DocumentViewPicker(ctx);
      const opts = new picker.DocumentSelectOptions();
      opts.selectMode = picker.DocumentSelectMode.FOLDER;
      const uris: string[] = await p.select(opts);
      if (uris && uris.length > 0) {
        this.folderUri = uris[0];
        const idx: number = this.folderUri.lastIndexOf('/');
        this.folderName = idx >= 0
          ? this.folderUri.substring(idx + 1)
          : this.folderUri;
      }
    } catch (e) {
      this.status = '选择文件夹失败: ' + (e as Error).message;
    }
  }

  private canInstall(): boolean {
    if (this.installing) return false;
    if (!this.cName.trim()) return false;
    if (this.currentSource === 'tar')     return !!this.archiveUri;
    if (this.currentSource === 'folder')  return !!this.folderUri;
    if (this.currentSource === 'builtin') return !!this.selectedBuiltin;
    return false;
  }

  private async doInstall(): Promise<void> {
    this.installing = true;
    this.status = '正在安装...';
    try {
      const ctx = getContext(this) as common.Context;
      const opts: InstallOptions = {
        source:      this.currentSource as 'tar' | 'folder' | 'network' | 'builtin',
        archiveUri:  this.archiveUri,
        folderUri:   this.folderUri,
        builtinId:   this.selectedBuiltin,
        name:        this.cName,
        description: this.cDescription,
        type:        this.cType
      };
      const r: InstallResult = await ContainerService.install(ctx, opts);
      if (r.ok && r.info) {
        this.status = '安装完成';
        this.onInstalled(r.info);
        setTimeout((): void => { this.controller?.close(); }, 400);
      } else {
        this.status = '安装失败: ' + r.error;
        this.installing = false;
      }
    } catch (e) {
      this.status = '安装异常: ' + (e as Error).message;
      this.installing = false;
    }
  }

  // ──────────────────────────────────────────────
  @Builder
  SourceNav() {
    Column() {
      ForEach(this.sources, (s: SourceOption): void => {
        Row({ space: 10 }) {
          Text(s.icon).fontSize(16)
          Text(s.label)
            .fontSize(13)
            .fontColor(this.currentSource === s.id
              ? Theme.TEXT_MAIN : Theme.TEXT_SEC)
            .fontWeight(this.currentSource === s.id
              ? FontWeight.Medium : FontWeight.Regular)
          if (!s.enabled) {
            Blank()
            Text('未开放').fontSize(10).fontColor(Theme.TEXT_HINT)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor('#EDEFF2').borderRadius(4)
          }
        }
        .width('100%').height(40)
        .padding({ left: 14, right: 10 })
        .borderRadius(8)
        .opacity(s.enabled ? 1 : 0.5)
        .backgroundColor(this.currentSource === s.id
          ? '#F5F7FA' : '#00000000')
        .onClick((): void => {
          if (s.enabled) this.currentSource = s.id;
        })
      }, (s: SourceOption): string => s.id)
    }
    .width(180).height('100%')
    .padding({ top: 20, left: 12, right: 12 })
    .backgroundColor('#FAFBFC')
    .border({ width: { right: 1 }, color: Theme.BORDER_LIGHT })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  MainContent() {
    Column() {
      if (this.currentSource === 'tar')     this.PanelTar()
      else if (this.currentSource === 'folder')  this.PanelFolder()
      else if (this.currentSource === 'network') this.PanelNetwork()
      else                                       this.PanelBuiltin()

      // 通用字段: 名称/描述/类型
      if (this.currentSource === 'tar' || this.currentSource === 'folder'  || this.currentSource === 'builtin') {
        Divider().color(Theme.BORDER_LIGHT).margin({ top: 16, bottom: 12 })
        this.FormFields()
      }
    }
    .layoutWeight(1).height('100%')
    .padding(24)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  PanelTar() {
    Text('从 tar 包安装')
      .fontSize(18).fontWeight(FontWeight.Medium)
      .fontColor(Theme.TEXT_MAIN)
    Text('容器目录会解压到 filesDir/containers/<id>/')
      .fontSize(12).fontColor(Theme.TEXT_HINT)
      .margin({ top: 4, bottom: 16 })

    Row({ space: 10 }) {
      Button('选择 tar 文件')
        .fontSize(13).height(36)
        .backgroundColor(Theme.HM_BLUE)
        .onClick((): void => { this.chooseTar(); })
      Text(this.archiveName || '尚未选择')
        .fontSize(13).layoutWeight(1)
        .fontColor(this.archiveName ? Theme.TEXT_MAIN : Theme.TEXT_HINT)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')

    Text('tar 包内必须包含 container.json 配置文件')
      .fontSize(11).fontColor(Theme.TEXT_HINT)
      .margin({ top: 8 })
  }

  @Builder
  PanelFolder() {
    Text('从文件夹安装')
      .fontSize(18).fontWeight(FontWeight.Medium)
      .fontColor(Theme.TEXT_MAIN)
    Text('选中的文件夹会整体复制到容器目录')
      .fontSize(12).fontColor(Theme.TEXT_HINT)
      .margin({ top: 4, bottom: 16 })

    Row({ space: 10 }) {
      Button('选择文件夹')
        .fontSize(13).height(36)
        .backgroundColor(Theme.HM_BLUE)
        .onClick((): void => { this.chooseFolder(); })
      Text(this.folderName || '尚未选择')
        .fontSize(13).layoutWeight(1)
        .fontColor(this.folderName ? Theme.TEXT_MAIN : Theme.TEXT_HINT)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
  }

  @Builder
  PanelNetwork() {
    Text('从网络安装')
      .fontSize(18).fontWeight(FontWeight.Medium)
      .fontColor(Theme.TEXT_MAIN)
    Text('从预设的镜像仓库或指定 URL 下载')
      .fontSize(12).fontColor(Theme.TEXT_HINT)
      .margin({ top: 4, bottom: 20 })

    Column({ space: 8 }) {
      Text('🚧 功能开发中')
        .fontSize(14).fontColor(Theme.TEXT_SEC)
      Text('后续将支持从官方仓库、镜像站、自定义 URL 下载容器')
        .fontSize(12).fontColor(Theme.TEXT_HINT)
    }
    .width('100%').height(160).justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#F5F7FA').borderRadius(8)
  }

  @State selectedBuiltin: string = '';

  @Builder
  PanelBuiltin() {
    Text('内置容器')
      .fontSize(18).fontWeight(FontWeight.Medium)
      .fontColor(Theme.TEXT_MAIN)
    Text('随应用打包的预置容器, 一键安装')
      .fontSize(12).fontColor(Theme.TEXT_HINT)
      .margin({ top: 4, bottom: 16 })

    Column({ space: 10 }) {
      ForEach(this.builtins, (b: BuiltinEntry): void => {
        Row({ space: 12 }) {
          Text(b.type === ContainerType.WINE ? '🍷' : '🐧').fontSize(24)
          Column() {
            Text(b.name).fontSize(14).fontColor(Theme.TEXT_MAIN)
              .fontWeight(FontWeight.Medium)
            Text(b.desc).fontSize(11).fontColor(Theme.TEXT_HINT)
              .margin({ top: 2 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)

          if (this.selectedBuiltin === b.id) {
            Text('✓').fontSize(14).fontColor(Theme.HM_BLUE)
          }
        }
        .width('100%').padding(14)
        .backgroundColor(this.selectedBuiltin === b.id ? Theme.HM_BLUE_SOFT : '#F5F7FA')
        .borderRadius(8)
        .border({
          width: this.selectedBuiltin === b.id ? 1 : 0,
          color: Theme.HM_BLUE
        })
        .onClick((): void => {
          this.selectedBuiltin = b.id;
          this.cType = b.type;
          if (!this.cName) this.cName = b.id;
        })
      }, (b: BuiltinEntry): string => b.id)
    }
    .width('100%')

    Text('选择后可在下方填入容器名称，之后开始安装')
      .fontSize(11).fontColor(Theme.TEXT_HINT)
      .margin({ top: 12 })
  }

  @Builder
  FormFields() {
    this.Label('容器名称 *')
    TextInput({ placeholder: '如: wine-mainline', text: this.cName })
      .height(36).fontSize(13).width('100%')
      .onChange((v: string): void => { this.cName = v; })
    Text('将作为容器目录名, 支持中文/英文/数字/连字符')
      .fontSize(11).fontColor(Theme.TEXT_HINT)
      .margin({ top: 4 })

    this.Label('容器类型')
    Row({ space: 8 }) {
      ForEach(this.types, (t: ContainerType): void => {
        Text(containerTypeLabel(t))
          .fontSize(13)
          .fontColor(this.cType === t ? Color.White : Theme.TEXT_MAIN)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor(this.cType === t ? Theme.HM_BLUE : '#F0F0F0')
          .borderRadius(8)
          .onClick((): void => { this.cType = t; })
      }, (t: ContainerType): string => t)
    }

    this.Label('描述 (可选)')
    TextArea({ placeholder: '容器用途说明', text: this.cDescription })
      .height(60).fontSize(12).width('100%')
      .onChange((v: string): void => { this.cDescription = v; })
  }

  @Builder
  Label(t: string) {
    Text(t).fontSize(12).fontColor(Theme.TEXT_SEC)
      .fontWeight(FontWeight.Medium)
      .margin({ top: 14, bottom: 6 })
  }

  build() {
    Column() {
      // header
      Row() {
        Text('创建容器').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_MAIN).layoutWeight(1)
        Text('✕').fontSize(16).fontColor(Theme.TEXT_HINT)
          .padding(6)
          .onClick((): void => { this.controller?.close(); })
      }
      .width('100%').height(48)
      .padding({ left: 20, right: 12 })
      .border({ width: { bottom: 1 }, color: Theme.BORDER_LIGHT })

      // body
      Row() {
        this.SourceNav()
        this.MainContent()
      }
      .width('100%').layoutWeight(1)

      // footer
      Row({ space: 12 }) {
        if (this.status.length > 0) {
          Text(this.status).fontSize(12)
            .fontColor(this.status.startsWith('安装失败')
              || this.status.startsWith('安装异常')
              ? '#E64545' : Theme.TEXT_SEC)
            .layoutWeight(1)
        } else {
          Blank()
        }
        Button('取消')
          .fontSize(13).height(36).width(90)
          .backgroundColor('#F0F0F0').fontColor(Theme.TEXT_MAIN)
          .onClick((): void => { this.controller?.close(); })
        Button(this.installing ? '安装中...' : '开始安装')
          .fontSize(13).height(36).width(120)
          .backgroundColor(this.canInstall() ? Theme.HM_BLUE : '#B0B7C0')
          .enabled(this.canInstall())
          .onClick((): void => { this.doInstall(); })
      }
      .width('100%').height(60)
      .padding({ left: 20, right: 20 })
      .backgroundColor('#FAFBFC')
      .border({ width: { top: 1 }, color: Theme.BORDER_LIGHT })
    }
    .width(720).height(540)
    .backgroundColor(Theme.HM_CARD)
    .borderRadius(Theme.RADIUS_LG)
    .clip(true)
  }
}