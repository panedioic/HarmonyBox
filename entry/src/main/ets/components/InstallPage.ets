import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import {
  AppInfo, AppType, RuntimeMode,
  appTypeLabel, runtimeModeLabel, isTypeSupported, AppConfig
} from '../model/AppInfo';
import { InstallService } from '../service/InstallService';

@Component
export struct InstallPage {
  @State selectedType: AppType = AppType.LINUX64;
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

  onInstalled: (app: AppInfo) => void = () => {};

  private allTypes: AppType[] = [
    AppType.WIN32, AppType.WIN64,
    AppType.LINUX32, AppType.LINUX64,
    AppType.HARMONY
  ];

  private allModes: RuntimeMode[] = [RuntimeMode.GUI, RuntimeMode.CLI];

  async chooseFolder(): Promise<void> {
    const uri: string | null = await InstallService.pickFolder();
    if (uri) {
      this.sourceFolderUri = uri;
      this.sourceFolderName = InstallService.folderNameFromUri(uri);
      if (!this.appName) {
        this.appName = this.sourceFolderName;
      }
    }
  }

  async chooseExecFile(): Promise<void> {
    if (!this.sourceFolderUri) {
      this.statusText = '请先选择应用文件夹';
      return;
    }
    const fileUri: string | null = await InstallService.pickFile();
    if (!fileUri) {
      return;
    }
    const rel: string | null = InstallService.relativePath(
      this.sourceFolderUri, fileUri
    );
    if (rel === null) {
      this.statusText = '主程序必须位于已选文件夹内,请重新选择';
      return;
    }
    this.execRelPath = rel;
    this.statusText = '';
  }

  async startInstall(): Promise<void> {
    if (!isTypeSupported(this.selectedType)) {
      this.statusText = `暂不支持 ${appTypeLabel(this.selectedType)}`;
      return;
    }
    if (!this.sourceFolderUri) {
      this.statusText = '请先选择应用文件夹';
      return;
    }
    if (!this.execRelPath.trim()) {
      this.statusText = '请填写主可执行文件路径';
      return;
    }
    if (!this.appName.trim()) {
      this.statusText = '请填写应用名称';
      return;
    }

    this.installing = true;
    this.progress = 10;
    this.statusText = '正在创建沙箱目录...';

    try {
      const context = getContext(this) as common.Context;
      const appId: string = `app_${Date.now()}`;

      this.progress = 30;
      this.statusText = '正在复制文件到沙箱...';

      const installDir: string = InstallService.installFromUri(
        context, this.sourceFolderUri, appId
      );

      this.progress = 80;
      this.statusText = '正在写入注册表...';

      const config: AppConfig = {
        envVars: this.envVars,
        args: this.launchArgs
      };

      const app: AppInfo = new AppInfo(
        appId,
        this.appName.trim(),
        this.appIcon || '📦',
        this.selectedType,
        this.runtimeMode,
        this.execRelPath.trim(),
        installDir,
        Date.now(),
        config
      );

      this.progress = 100;
      this.statusText = '安装完成';

      setTimeout(() => {
        this.onInstalled(app);
        this.resetForm();
      }, 600);
    } catch (e) {
      console.error(`install failed: ${JSON.stringify(e)}`);
      const msg: string = (e as Error).message || '未知错误';
      this.statusText = `安装失败: ${msg}`;
      this.installing = false;
    }
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
    this.selectedType = AppType.LINUX64;
    this.runtimeMode = RuntimeMode.GUI;
  }

  @Builder
  TypeChip(type: AppType) {
    Text(appTypeLabel(type))
      .fontSize(13)
      .fontColor(this.selectedType === type ? Color.White : '#333333')
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(
        this.selectedType === type
          ? Theme.HM_BLUE
          : (isTypeSupported(type) ? '#F0F0F0' : '#F8F8F8')
      )
      .borderRadius(8)
      .opacity(isTypeSupported(type) ? 1 : 0.5)
      .margin({ right: 10, bottom: 10 })
      .onClick(() => {
        this.selectedType = type;
      })
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
      .onClick(() => {
        this.runtimeMode = mode;
      })
  }

  @Builder
  SectionLabel(title: string) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor('#666666')
      .margin({ top: 14, bottom: 10 })
  }

  build() {
    Scroll() {
      Column() {
        Text('安装新应用程序')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 16 })

        Column() {
          // —— 应用类型 ——
          this.SectionLabel('应用类型')

          Flex({
            direction: FlexDirection.Row,
            wrap: FlexWrap.Wrap,
            justifyContent: FlexAlign.Start
          }) {
            ForEach(this.allTypes, (t: AppType) => {
              this.TypeChip(t)
            }, (t: AppType) => t)
          }
          .width('100%')

          Text('目前仅支持 64 位 Linux 应用,其他类型即将到来')
            .fontSize(12)
            .fontColor('#999999')

          Divider().color('#EEEEEE').margin({ top: 14 })

          // —— 运行模式 ——
          this.SectionLabel('运行模式')

          Row() {
            ForEach(this.allModes, (m: RuntimeMode) => {
              this.ModeChip(m)
            }, (m: RuntimeMode) => m)
          }
          .width('100%')

          Text(
            this.runtimeMode === RuntimeMode.GUI
              ? '将在窗口中渲染应用界面'
              : '在终端中运行,无窗口界面'
          )
            .fontSize(12)
            .fontColor('#999999')
            .margin({ top: 8 })

          Divider().color('#EEEEEE').margin({ top: 14 })

          // —— 应用文件夹 ——
          this.SectionLabel('应用文件夹')

          Row({ space: 12 }) {
            Button('选择文件夹')
              .fontSize(13)
              .height(36)
              .backgroundColor(Theme.HM_BLUE)
              .onClick(() => {
                this.chooseFolder();
              })

            Text(this.sourceFolderName || '尚未选择')
              .fontSize(13)
              .fontColor(this.sourceFolderName ? '#333333' : '#999999')
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')

          if (this.sourceFolderUri) {
            Text(this.sourceFolderUri)
              .fontSize(11)
              .fontColor('#AAAAAA')
              .width('100%')
              .margin({ top: 6 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }

          Divider().color('#EEEEEE').margin({ top: 14 })

          // —— 主可执行文件 ——
          this.SectionLabel('主可执行文件 (相对路径)')

          Row({ space: 8 }) {
            TextInput({
              placeholder: '例如: bin/app 或 main.exe',
              text: this.execRelPath
            })
              .layoutWeight(1)
              .height(36)
              .fontSize(13)
              .onChange((v: string) => {
                this.execRelPath = v;
              })

            Button('浏览...')
              .fontSize(13)
              .height(36)
              .backgroundColor('#F0F0F0')
              .fontColor('#333333')
              .onClick(() => {
                this.chooseExecFile();
              })
          }
          .width('100%')

          Text('可手动输入,或点击「浏览…」从已选文件夹中选取')
            .fontSize(11)
            .fontColor('#AAAAAA')
            .margin({ top: 6 })

          Divider().color('#EEEEEE').margin({ top: 14 })

          // —— 应用名称 ——
          this.SectionLabel('应用名称')

          TextInput({
            placeholder: '显示名称',
            text: this.appName
          })
            .height(36)
            .fontSize(13)
            .onChange((v: string) => {
              this.appName = v;
            })

          // —— 图标 ——
          this.SectionLabel('应用图标 (Emoji)')

          TextInput({
            placeholder: '📦',
            text: this.appIcon
          })
            .height(36)
            .width(120)
            .fontSize(16)
            .onChange((v: string) => {
              this.appIcon = v;
            })

          Divider().color('#EEEEEE').margin({ top: 14 })

          this.SectionLabel('环境变量')

          TextArea({
            placeholder: 'KEY=VALUE,可多行或用 ; 分隔\n可用占位符: ${X64_LIBS}, ${FILES_DIR}',
            text: this.envVars
          })
            .height(80)
            .fontSize(13)
            .onChange((v: string): void => {
              this.envVars = v;
            })

          Text('示例: LD_PRELOAD=${X64_LIBS}/libforkpty_shim.so')
            .fontSize(11)
            .fontColor('#999999')
            .margin({ top: 4 })

          this.SectionLabel('启动参数')

          TextInput({
            placeholder: '--debug --port=8080',
            text: this.launchArgs
          })
            .height(36)
            .fontSize(13)
            .onChange((v: string): void => {
              this.launchArgs = v;
            })
        }
        .padding(20)
        .backgroundColor(Color.White)
        .borderRadius(Theme.RADIUS)
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        // —— 安装按钮与进度 ——
        Column({ space: 12 }) {
          Button(this.installing ? '安装中...' : '开始安装')
            .width('100%')
            .height(44)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .backgroundColor(this.installing ? '#AAAAAA' : Theme.HM_BLUE)
            .enabled(!this.installing)
            .onClick(() => {
              this.startInstall();
            })

          if (this.installing || this.statusText) {
            Text(this.statusText)
              .fontSize(13)
              .fontColor(
                this.statusText.startsWith('安装失败') || this.statusText.startsWith('暂不支持') ? '#E64545' : '#666666'
              )
          }

          if (this.installing) {
            Stack({ alignContent: Alignment.Start }) {
              Row()
                .width('100%').height(6)
                .backgroundColor('#EEEEEE').borderRadius(3)
              Row()
                .width(`${this.progress}%`).height(6)
                .backgroundColor(Theme.HM_BLUE).borderRadius(3)
                .animation({ duration: 250, curve: Curve.EaseOut })
            }
            .width('100%')
          }
        }
        .margin({ top: 20 })
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
  }
}