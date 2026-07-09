// entry/src/main/ets/components/InstallAppDialog.ets
import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import {
  AppInfo, AppType, RuntimeMode,
  appTypeLabel, runtimeModeLabel, isTypeSupported, AppConfig
} from '../model/AppInfo';
import { InstallService } from '../service/InstallService';

interface WizardStep {
  id: number;
  label: string;
  icon: string;
}

@CustomDialog
export struct InstallAppDialog {
  controller?: CustomDialogController;
  onInstalled: (app: AppInfo) => void = () => {};

  // 步骤
  @State step: number = 0;
  private steps: WizardStep[] = [
    { id: 0, label: '选择安装包', icon: '📦' },
    { id: 1, label: '配置环境',   icon: '⚙️' },
    { id: 2, label: '安装依赖',   icon: '📚' },
    { id: 3, label: '确认安装',   icon: '✅' }
  ];

  // 表单状态
  @State sourceFolderUri: string = '';
  @State sourceFolderName: string = '';
  @State execRelPath: string = '';
  @State selectedType: AppType = AppType.LINUX;
  @State runtimeMode: RuntimeMode = RuntimeMode.GUI;
  @State appName: string = '';
  @State appIcon: string = '📦';
  @State envVars: string = '';
  @State launchArgs: string = '';

  @State installing: boolean = false;
  @State statusText: string = '';
  @State progress: number = 0;

  private allTypes: AppType[] = [AppType.WINDOWS, AppType.LINUX, AppType.HARMONY];
  private allModes: RuntimeMode[] = [RuntimeMode.GUI, RuntimeMode.CLI];

  // ==============================================================
  // 步骤操作
  // ==============================================================
  private canGoNext(): boolean {
    if (this.step === 0) return !!this.sourceFolderUri && !!this.execRelPath.trim();
    if (this.step === 1) return !!this.appName.trim();
    if (this.step === 2) return true;
    return true;
  }

  private next(): void {
    if (this.step < this.steps.length - 1) this.step++;
  }

  private prev(): void {
    if (this.step > 0) this.step--;
  }

  private cancel(): void {
    this.controller?.close();
  }

  private async chooseFolder(): Promise<void> {
    const uri: string | null = await InstallService.pickFolder();
    if (uri) {
      this.sourceFolderUri = uri;
      this.sourceFolderName = InstallService.folderNameFromUri(uri);
      if (!this.appName) this.appName = this.sourceFolderName;
    }
  }

  private async chooseExecFile(): Promise<void> {
    if (!this.sourceFolderUri) {
      this.statusText = '请先选择应用文件夹';
      return;
    }
    const fileUri: string | null = await InstallService.pickFile();
    if (!fileUri) return;
    const rel: string | null =
      InstallService.relativePath(this.sourceFolderUri, fileUri);
    if (rel === null) {
      this.statusText = '主程序必须位于已选文件夹内';
      return;
    }
    this.execRelPath = rel;
    this.statusText = '';
  }

  private async doInstall(): Promise<void> {
    if (!isTypeSupported(this.selectedType)) {
      this.statusText = `暂不支持 ${appTypeLabel(this.selectedType)}`;
      return;
    }
    this.installing = true;
    this.progress = 20;
    this.statusText = '正在复制文件到沙箱...';

    try {
      const ctx = getContext(this) as common.Context;
      const appId: string = `app_${Date.now()}`;
      const installDir: string = InstallService.installFromUri(
        ctx, this.sourceFolderUri, appId
      );
      this.progress = 90;
      this.statusText = '正在写入注册表...';

      const config: AppConfig = {
        envVars: this.envVars,
        args: this.launchArgs
      };
      const app: AppInfo = new AppInfo(
        appId, this.appName.trim(), this.appIcon || '📦',
        this.selectedType, this.runtimeMode,
        this.execRelPath.trim(), installDir, Date.now(), config
      );
      this.progress = 100;
      this.statusText = '安装完成';
      setTimeout((): void => {
        this.onInstalled(app);
        this.controller?.close();
      }, 500);
    } catch (e) {
      const msg: string = (e as Error).message || '未知错误';
      this.statusText = `安装失败: ${msg}`;
      this.installing = false;
    }
  }

  // ==============================================================
  // Builders
  // ==============================================================
  @Builder
  StepNav() {
    Column() {
      ForEach(this.steps, (s: WizardStep): void => {
        Row({ space: 10 }) {
          // 圆点
          Column() {
            Text(this.step >= s.id ? s.icon : `${s.id + 1}`)
              .fontSize(this.step >= s.id ? 14 : 12)
              .fontColor(this.step === s.id
                ? Color.White
                : (this.step > s.id ? Theme.HM_BLUE : Theme.TEXT_HINT))
              .fontWeight(FontWeight.Medium)
          }
          .width(28).height(28)
          .borderRadius(14)
          .backgroundColor(this.step === s.id
            ? Theme.HM_BLUE
            : (this.step > s.id ? Theme.HM_BLUE_SOFT : '#EDEFF2'))
          .justifyContent(FlexAlign.Center)

          Text(s.label)
            .fontSize(13)
            .fontColor(this.step === s.id ? Theme.TEXT_MAIN : Theme.TEXT_SEC)
            .fontWeight(this.step === s.id ? FontWeight.Medium : FontWeight.Regular)
        }
        .width('100%')
        .height(44)
        .padding({ left: 14 })
        .borderRadius(8)
        .backgroundColor(this.step === s.id ? '#F5F7FA' : '#00000000')
      }, (s: WizardStep): string => `${s.id}`)
    }
    .width(180)
    .height('100%')
    .padding({ top: 20, left: 12, right: 12 })
    .backgroundColor('#FAFBFC')
    .border({ width: { right: 1 }, color: Theme.BORDER_LIGHT })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  StepContent() {
    Column() {
      if (this.step === 0) {
        this.Step0()
      } else if (this.step === 1) {
        this.Step1()
      } else if (this.step === 2) {
        this.Step2()
      } else {
        this.Step3()
      }
    }
    .layoutWeight(1)
    .height('100%')
    .padding(24)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  Step0() {
    Text('选择安装包')
      .fontSize(18).fontWeight(FontWeight.Medium)
      .fontColor(Theme.TEXT_MAIN)
    Text('选择应用文件夹和主可执行文件')
      .fontSize(12).fontColor(Theme.TEXT_HINT)
      .margin({ top: 4, bottom: 20 })

    // 应用类型
    this.FieldLabel('应用类型')
    Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
      ForEach(this.allTypes, (t: AppType): void => {
        this.TypeChip(t)
      }, (t: AppType): string => t)
    }
    .width('100%').margin({ bottom: 8 })

    // 文件夹
    this.FieldLabel('应用文件夹')
    Row({ space: 12 }) {
      Button('选择文件夹')
        .fontSize(13).height(36)
        .backgroundColor(Theme.HM_BLUE)
        .onClick((): void => { this.chooseFolder(); })
      Text(this.sourceFolderName || '尚未选择')
        .fontSize(13).layoutWeight(1)
        .fontColor(this.sourceFolderName ? Theme.TEXT_MAIN : Theme.TEXT_HINT)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%').margin({ bottom: 16 })

    // 可执行文件
    this.FieldLabel('主可执行文件 (相对路径)')
    Row({ space: 8 }) {
      TextInput({ placeholder: 'bin/app 或 main.exe', text: this.execRelPath })
        .layoutWeight(1).height(36).fontSize(13)
        .onChange((v: string): void => { this.execRelPath = v; })
      Button('浏览...')
        .fontSize(13).height(36)
        .backgroundColor('#F0F0F0').fontColor(Theme.TEXT_MAIN)
        .onClick((): void => { this.chooseExecFile(); })
    }
    .width('100%')
  }

  @Builder
  Step1() {
    Text('配置环境')
      .fontSize(18).fontWeight(FontWeight.Medium)
      .fontColor(Theme.TEXT_MAIN)
    Text('填写应用信息与启动参数')
      .fontSize(12).fontColor(Theme.TEXT_HINT)
      .margin({ top: 4, bottom: 20 })

    this.FieldLabel('运行模式')
    Row() {
      ForEach(this.allModes, (m: RuntimeMode): void => {
        this.ModeChip(m)
      }, (m: RuntimeMode): string => m)
    }
    .width('100%').margin({ bottom: 16 })

    this.FieldLabel('应用名称')
    TextInput({ placeholder: '显示名称', text: this.appName })
      .height(36).fontSize(13).width('100%')
      .onChange((v: string): void => { this.appName = v; })

    Row({ space: 12 }) {
      Column() {
        this.FieldLabel('图标 (Emoji)')
        TextInput({ placeholder: '📦', text: this.appIcon })
          .height(36).width(100).fontSize(16)
          .onChange((v: string): void => { this.appIcon = v; })
      }
      .alignItems(HorizontalAlign.Start)
      Column() {
        this.FieldLabel('启动参数')
        TextInput({ placeholder: '--debug', text: this.launchArgs })
          .height(36).fontSize(13)
          .onChange((v: string): void => { this.launchArgs = v; })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%').margin({ top: 8 })

    this.FieldLabel('环境变量')
    TextArea({
      placeholder: 'KEY=VALUE\n可用: ${X64_LIBS}, ${FILES_DIR}',
      text: this.envVars
    })
      .height(90).fontSize(12).width('100%')
      .onChange((v: string): void => { this.envVars = v; })
  }

  @Builder
  Step2() {
    Text('安装依赖')
      .fontSize(18).fontWeight(FontWeight.Medium)
      .fontColor(Theme.TEXT_MAIN)
    Text('检查运行环境所需依赖')
      .fontSize(12).fontColor(Theme.TEXT_HINT)
      .margin({ top: 4, bottom: 20 })

    // 依据 selectedType 检查
    Column({ space: 12 }) {
      this.DepRow('容器 (box64)', true)
      if (this.selectedType === AppType.WINDOWS) {
        this.DepRow('Wine 环境', true)
        this.DepRow('WinePrefix', true)
      }
      this.DepRow('字体资源', true)
    }
    .width('100%')

    Text('未来会自动检测缺失项并提示安装')
      .fontSize(11).fontColor(Theme.TEXT_HINT)
      .margin({ top: 20 })
  }

  @Builder
  DepRow(name: string, ok: boolean) {
    Row({ space: 10 }) {
      Text(ok ? '✅' : '⚠️').fontSize(14)
      Text(name).fontSize(13).fontColor(Theme.TEXT_MAIN).layoutWeight(1)
      Text(ok ? '已就绪' : '缺失')
        .fontSize(12)
        .fontColor(ok ? '#5DD46E' : '#FF9F43')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor('#F5F7FA')
    .borderRadius(8)
  }

  @Builder
  Step3() {
    Text('确认安装')
      .fontSize(18).fontWeight(FontWeight.Medium)
      .fontColor(Theme.TEXT_MAIN)
    Text('请核对以下信息后开始安装')
      .fontSize(12).fontColor(Theme.TEXT_HINT)
      .margin({ top: 4, bottom: 20 })

    Column({ space: 10 }) {
      this.SummaryRow('应用名称', this.appName || '(未填写)')
      this.SummaryRow('类型',     appTypeLabel(this.selectedType))
      this.SummaryRow('运行模式', runtimeModeLabel(this.runtimeMode))
      this.SummaryRow('主程序',   this.execRelPath || '(未指定)')
      this.SummaryRow('源目录',   this.sourceFolderName || '(未选择)')
    }
    .width('100%')

    if (this.statusText) {
      Text(this.statusText)
        .fontSize(13)
        .fontColor(this.statusText.startsWith('安装失败')
          || this.statusText.startsWith('暂不支持')
          ? '#E64545' : Theme.TEXT_SEC)
        .margin({ top: 16 })
    }
    if (this.installing) {
      Stack({ alignContent: Alignment.Start }) {
        Row().width('100%').height(6)
          .backgroundColor('#EEEEEE').borderRadius(3)
        Row().width(`${this.progress}%`).height(6)
          .backgroundColor(Theme.HM_BLUE).borderRadius(3)
          .animation({ duration: 250, curve: Curve.EaseOut })
      }
      .width('100%')
      .margin({ top: 10 })
    }
  }

  @Builder
  SummaryRow(k: string, v: string) {
    Row() {
      Text(k).fontSize(13).fontColor(Theme.TEXT_HINT).width(80)
      Text(v).fontSize(13).fontColor(Theme.TEXT_MAIN).layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor('#F5F7FA')
    .borderRadius(8)
  }

  @Builder
  FieldLabel(t: string) {
    Text(t)
      .fontSize(12)
      .fontColor(Theme.TEXT_SEC)
      .fontWeight(FontWeight.Medium)
      .margin({ top: 6, bottom: 8 })
  }

  @Builder
  TypeChip(t: AppType) {
    Text(appTypeLabel(t))
      .fontSize(13)
      .fontColor(this.selectedType === t ? Color.White : Theme.TEXT_MAIN)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.selectedType === t
        ? Theme.HM_BLUE
        : (isTypeSupported(t) ? '#F0F0F0' : '#F8F8F8'))
      .borderRadius(8)
      .opacity(isTypeSupported(t) ? 1 : 0.5)
      .margin({ right: 10, bottom: 10 })
      .onClick((): void => { this.selectedType = t; })
  }

  @Builder
  ModeChip(m: RuntimeMode) {
    Text(runtimeModeLabel(m))
      .fontSize(13)
      .fontColor(this.runtimeMode === m ? Color.White : Theme.TEXT_MAIN)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.runtimeMode === m ? Theme.HM_BLUE : '#F0F0F0')
      .borderRadius(8)
      .margin({ right: 10 })
      .onClick((): void => { this.runtimeMode = m; })
  }

  build() {
    Column() {
      // Header
      Row() {
        Text('安装应用').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_MAIN)
          .layoutWeight(1)
        Text('✕').fontSize(16).fontColor(Theme.TEXT_HINT)
          .padding(6)
          .onClick((): void => { this.cancel(); })
      }
      .width('100%').height(48)
      .padding({ left: 20, right: 12 })
      .border({ width: { bottom: 1 }, color: Theme.BORDER_LIGHT })

      // Body: 左步骤 + 右内容
      Row() {
        this.StepNav()
        this.StepContent()
      }
      .width('100%').layoutWeight(1)

      // Footer
      Row({ space: 12 }) {
        Blank()
        Button('取消')
          .fontSize(13).height(36).width(90)
          .backgroundColor('#F0F0F0').fontColor(Theme.TEXT_MAIN)
          .onClick((): void => { this.cancel(); })
        if (this.step > 0) {
          Button('上一步')
            .fontSize(13).height(36).width(90)
            .backgroundColor('#F0F0F0').fontColor(Theme.TEXT_MAIN)
            .onClick((): void => { this.prev(); })
        }
        if (this.step < this.steps.length - 1) {
          Button('下一步')
            .fontSize(13).height(36).width(90)
            .backgroundColor(this.canGoNext() ? Theme.HM_BLUE : '#B0B7C0')
            .enabled(this.canGoNext())
            .onClick((): void => { this.next(); })
        } else {
          Button(this.installing ? '安装中...' : '开始安装')
            .fontSize(13).height(36).width(120)
            .backgroundColor(this.installing ? '#B0B7C0' : Theme.HM_BLUE)
            .enabled(!this.installing)
            .onClick((): void => { this.doInstall(); })
        }
      }
      .width('100%').height(60)
      .padding({ left: 20, right: 20 })
      .border({ width: { top: 1 }, color: Theme.BORDER_LIGHT })
      .backgroundColor('#FAFBFC')
    }
    .width(720)
    .height(520)
    .backgroundColor(Theme.HM_CARD)
    .borderRadius(Theme.RADIUS_LG)
    .clip(true)
  }
}