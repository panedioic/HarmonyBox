import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { Theme } from '../common/Theme';
import { AppInfo, RuntimeMode, AppConfig, BuiltinAppEntry, BUILTIN_APPS } from '../model/AppInfo';
import { ContainerInfo, ContainerType } from '../model/ContainerInfo';
import { ContainerService } from '../service/ContainerService';
import { PackageService, PackageResult } from '../service/PackageService';
import { InstallService } from '../service/InstallService';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HBox_UI_InstallApp';

interface SourceOption {
  id: 'builtin' | 'tar' | 'folder';
  label: string;
  icon: string;
}

interface KVItem {
  title: string,
  value: string
}

@CustomDialog
export struct InstallAppDialog {
  controller?: CustomDialogController;
  onInstalled: (app: AppInfo) => void = () => {};

  // 来源
  @State currentSource: string = 'builtin';
  private sources: SourceOption[] = [
    { id: 'builtin', label: '内置应用', icon: '⭐' },
    { id: 'tar',     label: '本地 tar 包', icon: '📦' },
    { id: 'folder',  label: '本地文件夹', icon: '📁' }
  ];

  // 容器
  @State containers: ContainerInfo[] = [];
  @State selectedContainerId: string = '';

  // 内置
  @State selectedBuiltinId: string = '';

  // tar
  @State archiveUri: string = '';
  @State archiveName: string = '';

  // folder
  @State folderUri: string = '';
  @State folderName: string = '';
  @State execRelPath: string = '';

  // 表单 (仅 tar/folder 可编辑)
  @State appName: string = '';
  @State appIcon: string = '📦';
  @State envVars: string = '';
  @State launchArgs: string = '';
  @State runtimeMode: RuntimeMode = RuntimeMode.GUI;

  // 状态
  @State installing: boolean = false;
  @State statusText: string = '';

  // 新增 @State，用于实时刷新信息
  @State builtinName: string = '';
  @State builtinExec: string = '';
  @State builtinMode: string = '';
  @State builtinArgs: string = '';
  @State builtinEnv:  string = '';

  @State useAppJson: boolean = false;

  private allModes: RuntimeMode[] = [RuntimeMode.GUI, RuntimeMode.CLI];

  aboutToAppear(): void {
    const ctx = getContext(this) as common.Context;
    this.containers = ContainerService.list(ctx);
    if (this.containers.length > 0) {
      this.selectedContainerId = this.containers[0].id;
    }
  }

  // ==============================================================
  //  辅助
  // ==============================================================
  private getSelectedContainer(): ContainerInfo | null {
    for (const c of this.containers) {
      if (c.id === this.selectedContainerId) return c;
    }
    return null;
  }

  private getSelectedBuiltin(): BuiltinAppEntry | null {
    for (const b of BUILTIN_APPS) {
      if (b.id === this.selectedBuiltinId) return b;
    }
    return null;
  }

  private canInstall(): boolean {
    if (this.installing) return false;
    if (!this.selectedContainerId) return false;
    if (this.currentSource === 'builtin') return !!this.selectedBuiltinId;
    if (this.currentSource === 'tar') return !!this.archiveUri && !!this.appName.trim();
    if (this.currentSource === 'folder') {
      return !!this.folderUri && !!this.execRelPath.trim() && !!this.appName.trim();
    }
    if (this.useAppJson) return false;   // 功能未实现
    return false;
  }

  private async chooseTar(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const p = new picker.DocumentViewPicker(ctx);
      const opts = new picker.DocumentSelectOptions();
      opts.selectMode = picker.DocumentSelectMode.FILE;
      opts.fileSuffixFilters = ['.zst', '.tar', '.gz', '.xz'];
      const uris: string[] = await p.select(opts);
      if (uris && uris.length > 0) {
        this.archiveUri = uris[0];
        const idx: number = this.archiveUri.lastIndexOf('/');
        this.archiveName = idx >= 0
          ? this.archiveUri.substring(idx + 1)
          : this.archiveUri;
        if (!this.appName) {
          this.appName = this.archiveName.replace(/\.(tar|tar\.zst|tar\.gz|tar\.xz|zst)$/i, '');
        }
      }
    } catch (e) {
      this.statusText = '选择文件失败: ' + (e as Error).message;
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
        if (!this.appName) this.appName = this.folderName;
      }
    } catch (e) {
      this.statusText = '选择文件夹失败: ' + (e as Error).message;
    }
  }

  private async chooseExecFile(): Promise<void> {
    if (!this.folderUri) {
      this.statusText = '请先选择应用文件夹';
      return;
    }
    const fileResult: string | null = await InstallService.pickFile();
    if (!fileResult) return;
    const rel: string | null =
      InstallService.relativePath(this.folderUri, fileResult);
    if (rel === null) {
      this.statusText = '主程序必须位于已选文件夹内';
      return;
    }
    this.execRelPath = rel;
    this.statusText = '';
  }

  // ==============================================================
  //  安装
  // ==============================================================
  private async doInstall(): Promise<void> {
    this.installing = true;
    this.statusText = '正在安装...';

    try {
      const ctx = getContext(this) as common.Context;
      const appId: string = `app_${Date.now()}`;
      const installRelDir: string = `apps/${appId}`;
      const installAbsDir: string = `${ctx.filesDir}/apps/${appId}`;

      let r: PackageResult;
      let finalName: string = this.appName;
      let finalIcon: string = this.appIcon;
      let finalExec: string = this.execRelPath;
      let finalMode: RuntimeMode = this.runtimeMode;
      let finalConfig: AppConfig = { envVars: this.envVars, args: this.launchArgs };

      if (this.currentSource === 'builtin') {
        const entry: BuiltinAppEntry | null = this.getSelectedBuiltin();
        if (!entry) {
          this.statusText = '未选择内置应用';
          this.installing = false;
          return;
        }
        finalName = entry.name;
        finalIcon = entry.icon;
        finalExec = entry.execRelPath;
        finalMode = entry.runtimeMode;
        finalConfig = entry.config;
        r = await PackageService.importFromRawfile(ctx, entry.rawfileName, installAbsDir);

      } else if (this.currentSource === 'tar') {
        r = await PackageService.importFromTar(ctx, this.archiveUri, installAbsDir);

      } else {
        r = PackageService.importFromFolder(this.folderUri, installAbsDir);
      }

      if (!r.ok) {
        this.statusText = '安装失败: ' + r.error;
        this.installing = false;
        return;
      }

      const app: AppInfo = new AppInfo(
        appId,
        finalName.trim(),
        finalIcon || '📦',
        'deprecated' as never,   // AppType (deprecated, 不再使用)
        finalMode,
        finalExec.trim(),
        installRelDir,
        Date.now(),
        finalConfig,
        this.selectedContainerId
      );

      this.statusText = '安装完成';
      hilog.info(0x0000, TAG, `[install] ok: ${app.name} -> ${installAbsDir}`);
      setTimeout((): void => {
        this.onInstalled(app);
        this.controller?.close();
      }, 400);

    } catch (e) {
      this.statusText = '安装异常: ' + (e as Error).message;
      this.installing = false;
    }
  }

  /** 根据当前面板返回可用容器 (内置模式按类型过滤) */
  private getMatchedContainers(): ContainerInfo[] {
    if (this.currentSource === 'builtin' && this.selectedBuiltinId) {
      const b: BuiltinAppEntry | null = this.getSelectedBuiltin();
      if (b) {
        return this.containers.filter((c: ContainerInfo): boolean =>
        c.config.type === b.containerType);
      }
    }
    return this.containers;
  }

  private getEmptyContainerHint(): string {
    if (this.currentSource === 'builtin' && this.selectedBuiltinId) {
      const b: BuiltinAppEntry | null = this.getSelectedBuiltin();
      if (b) {
        const label: string = b.containerType === ContainerType.WINE ? 'Wine' : 'Linux';
        return `当前没有 ${label} 类型的容器, 请先到容器管理中安装`;
      }
    }
    return '尚未安装任何容器, 请先到容器管理中安装';
  }

  // ==============================================================
  //  UI Builders
  // ==============================================================

  @Builder
  MainContent() {
    Scroll() {
      Column() {
        if (this.currentSource === 'builtin') this.PanelBuiltin()
        else if (this.currentSource === 'tar') this.PanelTar()
        else this.PanelFolder()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1).height('100%')
    .padding(24)
    .align(Alignment.TopStart)
    .scrollBar(BarState.Auto)
  }

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
        }
        .width('100%').height(40)
        .padding({ left: 14, right: 10 })
        .borderRadius(8)
        .backgroundColor(this.currentSource === s.id ? '#F5F7FA' : '#00000000')
        .onClick((): void => {
          this.currentSource = s.id;
          this.useAppJson = false;
        })
      }, (s: SourceOption): string => s.id)
    }
    .width(160).height('100%')
    .padding({ top: 20, left: 12, right: 12 })
    .backgroundColor('#FAFBFC')
    .border({ width: { right: 1 }, color: Theme.BORDER_LIGHT })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  AppJsonToggle() {
    Column() {
      Row({ space: 10 }) {
        Toggle({ type: ToggleType.Switch, isOn: this.useAppJson })
          .selectedColor(Theme.HM_BLUE)
          .onChange((on: boolean): void => { this.useAppJson = on; })
        Column() {
          Text('使用应用内 app.json')
            .fontSize(13).fontColor(Theme.TEXT_MAIN)
            .fontWeight(FontWeight.Medium)
          Text('从包内读取配置, 无需手动填写')
            .fontSize(11).fontColor(Theme.TEXT_HINT)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      if (this.useAppJson) {
        Row({ space: 6 }) {
          Text('🚧').fontSize(12)
          Text('该功能尚未实现, 暂无法安装')
            .fontSize(11).fontColor('#FF9F43')
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor('#FFF7EC').borderRadius(6)
        .margin({ top: 10 })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F5F7FA').borderRadius(8)
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 12 })
  }

  // ==============================================================
  //  内置应用: 列表 -> 详情 -> 容器
  // ==============================================================
  @Builder
  PanelBuiltin() {
    Column() {
      Text('内置应用')
        .fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_MAIN)
      Text('预装的示例应用, 选择后指定运行容器')
        .fontSize(11).fontColor(Theme.TEXT_HINT)
        .margin({ top: 4, bottom: 14 })

      // 全部内置应用列表 (从上到下)
      Column({ space: 8 }) {
        ForEach(BUILTIN_APPS, (b: BuiltinAppEntry): void => {
          Row({ space: 12 }) {
            Text(b.icon).fontSize(22)
            Column() {
              Row({ space: 6 }) {
                Text(b.name).fontSize(13)
                  .fontColor(Theme.TEXT_MAIN)
                  .fontWeight(FontWeight.Medium)
                Text(b.containerType === ContainerType.WINE ? '🍷 Wine' : '🐧 Linux')
                  .fontSize(10).fontColor(Theme.TEXT_SEC)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .backgroundColor('#EDEFF2')
                  .borderRadius(4)
              }
              Text(b.desc).fontSize(11)
                .fontColor(Theme.TEXT_HINT)
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            if (this.selectedBuiltinId === b.id) {
              Text('✓').fontSize(14).fontColor(Theme.HM_BLUE)
            }
          }
          .width('100%').padding(12)
          .backgroundColor(this.selectedBuiltinId === b.id
            ? Theme.HM_BLUE_SOFT : '#F5F7FA')
          .borderRadius(8)
          .border({
            width: this.selectedBuiltinId === b.id ? 1 : 0,
            color: Theme.HM_BLUE
          })
          .onClick((): void => {
            this.selectedBuiltinId = b.id;
            // 刷新详情字段
            this.builtinName = b.name;
            this.builtinExec = b.execRelPath;
            this.builtinMode = b.runtimeMode === RuntimeMode.GUI ? '图形界面' : '命令行';
            this.builtinArgs = b.config.args || '(无)';
            this.builtinEnv  = b.config.envVars || '(无)';
            // 选中后自动匹配一个同类型容器 (方便用户)
            const matched: ContainerInfo | undefined =
              this.containers.find((c: ContainerInfo): boolean =>
              c.config.type === b.containerType);
            this.selectedContainerId = matched ? matched.id : '';
          })
        }, (b: BuiltinAppEntry): string => b.id)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // 选中后: 详情 + 容器选择
      if (this.selectedBuiltinId) {
        Divider().color(Theme.BORDER_LIGHT).margin({ top: 16, bottom: 12 })
        this.BuiltinDetail()
        this.ContainerSelector()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 内置应用的只读详情卡 */
  @Builder
  BuiltinDetail() {
    Column({ space: 8 }) {
      Text('应用信息')
        .fontSize(12).fontColor(Theme.TEXT_SEC)
        .fontWeight(FontWeight.Medium)
      ForEach([
        {title: '名称',      value: this.builtinName},
        {title: '可执行文件', value: this.builtinExec},
        {title: '运行模式',   value: this.builtinMode},
        {title: '启动参数',   value: this.builtinArgs},
        {title: '环境变量',   value: this.builtinEnv}
      ], (item: KVItem): void => {
        Row({ space: 6 }) {
          Text(item.title).fontSize(11).fontColor(Theme.TEXT_HINT).width(80)
          Text(item.value).fontSize(12).fontColor(Theme.TEXT_MAIN)
            .layoutWeight(1)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      })
    }
    .width('100%').padding(12)
    .backgroundColor('#F5F7FA').borderRadius(8)
    .alignItems(HorizontalAlign.Start)
  }

  // ==============================================================
  //  tar 面板: 选文件 -> 表单 -> 容器
  // ==============================================================
  @Builder
  PanelTar() {
    Column() {
      Text('从 tar 包安装')
        .fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_MAIN)
      Text('选择归档文件, 解压到应用目录')
        .fontSize(11).fontColor(Theme.TEXT_HINT)
        .margin({ top: 4, bottom: 14 })

      Row({ space: 10 }) {
        Button('选择文件').fontSize(13).height(36)
          .backgroundColor(Theme.HM_BLUE)
          .onClick((): void => { this.chooseTar(); })
        Text(this.archiveName || '尚未选择')
          .fontSize(12).layoutWeight(1)
          .fontColor(this.archiveName ? Theme.TEXT_MAIN : Theme.TEXT_HINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      this.AppJsonToggle()

      if (!this.useAppJson) {
        Text('主可执行文件 (相对路径)')
          .fontSize(12).fontColor(Theme.TEXT_SEC)
          .fontWeight(FontWeight.Medium)
          .margin({ top: 12, bottom: 6 })
        TextInput({ placeholder: 'bin/app 或 main.exe', text: this.execRelPath })
          .height(36).fontSize(13).width('100%')
          .onChange((v: string): void => { this.execRelPath = v; })
        Text('解压后相对于应用根目录的路径')
          .fontSize(11).fontColor(Theme.TEXT_HINT)
          .margin({ top: 4 })

        Divider().color(Theme.BORDER_LIGHT).margin({ top: 14, bottom: 10 })
        this.EditableForm()
      }

      this.ContainerSelector()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ==============================================================
  //  folder 面板: 选文件夹 -> exec -> 表单 -> 容器
  // ==============================================================
  @Builder
  PanelFolder() {
    Column() {
      Text('从文件夹安装')
        .fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_MAIN)
      Text('选择应用文件夹, 整体复制到沙箱')
        .fontSize(11).fontColor(Theme.TEXT_HINT)
        .margin({ top: 4, bottom: 14 })

      Row({ space: 10 }) {
        Button('选择文件夹').fontSize(13).height(36)
          .backgroundColor(Theme.HM_BLUE)
          .onClick((): void => { this.chooseFolder(); })
        Text(this.folderName || '尚未选择')
          .fontSize(12).layoutWeight(1)
          .fontColor(this.folderName ? Theme.TEXT_MAIN : Theme.TEXT_HINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      this.AppJsonToggle()

      if (!this.useAppJson) {
        Text('主可执行文件 (相对路径)')
          .fontSize(12).fontColor(Theme.TEXT_SEC)
          .fontWeight(FontWeight.Medium)
          .margin({ top: 12, bottom: 6 })
        Row({ space: 8 }) {
          TextInput({ placeholder: 'bin/app 或 main.exe', text: this.execRelPath })
            .layoutWeight(1).height(36).fontSize(13)
            .onChange((v: string): void => { this.execRelPath = v; })
          Button('浏览...').fontSize(12).height(36)
            .backgroundColor('#F0F0F0').fontColor(Theme.TEXT_MAIN)
            .onClick((): void => { this.chooseExecFile(); })
        }
        .width('100%')

        Divider().color(Theme.BORDER_LIGHT).margin({ top: 14, bottom: 10 })
        this.EditableForm()
      }

      this.ContainerSelector()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ==============================================================
  //  编辑表单 (tar / folder 共用)
  // ==============================================================
  @Builder
  EditableForm() {
    Column() {
      Text('应用名称')
        .fontSize(12).fontColor(Theme.TEXT_SEC)
        .fontWeight(FontWeight.Medium).margin({ bottom: 6 })
      TextInput({ placeholder: '显示名称', text: this.appName })
        .height(36).fontSize(13).width('100%')
        .onChange((v: string): void => { this.appName = v; })

      Row({ space: 12 }) {
        Column() {
          Text('图标').fontSize(12).fontColor(Theme.TEXT_SEC)
            .fontWeight(FontWeight.Medium).margin({ top: 10, bottom: 6 })
          TextInput({ placeholder: '📦', text: this.appIcon })
            .height(36).width(80).fontSize(16)
            .onChange((v: string): void => { this.appIcon = v; })
        }.alignItems(HorizontalAlign.Start)

        Column() {
          Text('运行模式').fontSize(12).fontColor(Theme.TEXT_SEC)
            .fontWeight(FontWeight.Medium).margin({ top: 10, bottom: 6 })
          Row({ space: 6 }) {
            ForEach(this.allModes, (m: RuntimeMode): void => {
              Text(m === RuntimeMode.GUI ? '图形' : '命令行')
                .fontSize(12)
                .fontColor(this.runtimeMode === m ? Color.White : Theme.TEXT_MAIN)
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .backgroundColor(this.runtimeMode === m ? Theme.HM_BLUE : '#F0F0F0')
                .borderRadius(6)
                .onClick((): void => { this.runtimeMode = m; })
            }, (m: RuntimeMode): string => m)
          }
        }.alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Text('启动参数').fontSize(12).fontColor(Theme.TEXT_SEC)
        .fontWeight(FontWeight.Medium).margin({ top: 10, bottom: 6 })
      TextInput({ placeholder: '--debug --port=8080', text: this.launchArgs })
        .height(36).fontSize(13).width('100%')
        .onChange((v: string): void => { this.launchArgs = v; })

      Text('环境变量').fontSize(12).fontColor(Theme.TEXT_SEC)
        .fontWeight(FontWeight.Medium).margin({ top: 10, bottom: 6 })
      TextArea({ placeholder: 'KEY=VALUE (每行一个)', text: this.envVars })
        .height(70).fontSize(12).width('100%')
        .onChange((v: string): void => { this.envVars = v; })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ==============================================================
  //  容器选择器 (三种面板共用, 内置模式下按类型过滤)
  // ==============================================================
  @Builder
  ContainerSelector() {
    Column() {
      Text('运行容器')
        .fontSize(12).fontColor(Theme.TEXT_SEC)
        .fontWeight(FontWeight.Medium)
        .margin({ top: 14, bottom: 8 })

      if (this.getMatchedContainers().length === 0) {
        Row({ space: 8 }) {
          Text('⚠️').fontSize(14)
          Text(this.getEmptyContainerHint())
            .fontSize(12).fontColor('#E64545').layoutWeight(1)
        }
        .width('100%').padding(12)
        .backgroundColor('#FEF2F2').borderRadius(8)
      } else {
        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
          ForEach(this.getMatchedContainers(), (c: ContainerInfo): void => {
            Row({ space: 6 }) {
              Text(c.config.type === ContainerType.WINE ? '🍷' : '🐧').fontSize(14)
              Text(c.config.name).fontSize(12)
                .fontColor(this.selectedContainerId === c.id
                  ? Color.White : Theme.TEXT_MAIN)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .borderRadius(8)
            .backgroundColor(this.selectedContainerId === c.id
              ? Theme.HM_BLUE : '#F0F0F0')
            .margin({ right: 8, bottom: 8 })
            .onClick((): void => { this.selectedContainerId = c.id; })
          }, (c: ContainerInfo): string => c.id)
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ==============================================================
  //  build
  // ==============================================================
  build() {
    Column() {
      // header
      Row() {
        Text('安装应用').fontSize(16).fontWeight(FontWeight.Medium)
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
        if (this.statusText.length > 0) {
          Text(this.statusText).fontSize(12)
            .fontColor(this.statusText.startsWith('安装失败')
              || this.statusText.startsWith('安装异常')
              || this.statusText.startsWith('未')
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
    .width(720).height(560)
    .backgroundColor(Theme.HM_CARD)
    .borderRadius(Theme.RADIUS_LG)
    .clip(true)
  }
}