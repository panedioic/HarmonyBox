import { Theme } from '../common/Theme';
import { AppInfo, AppConfig } from '../model/AppInfo';

@CustomDialog
export struct EditAppDialog {
  controller?: CustomDialogController;
  app: AppInfo = new AppInfo();
  onSave: (updated: AppInfo) => void = () => {};

  @State editName: string = '';
  @State editIcon: string = '📦';
  @State editEnvVars: string = '';
  @State editArgs: string = '';

  aboutToAppear(): void {
    this.editName = this.app.name;
    this.editIcon = this.app.icon || '📦';
    this.editEnvVars = this.app.config.envVars || '';
    this.editArgs = this.app.config.args || '';
  }

  doSave(): void {
    const cfg: AppConfig = {
      envVars: this.editEnvVars,
      args: this.editArgs
    };
    const updated: AppInfo = new AppInfo(
      this.app.id,
      this.editName.trim() || this.app.name,
      this.editIcon || '📦',
      this.app.type,
      this.app.runtimeMode,
      this.app.execPath,
      this.app.installDir,
      this.app.installedAt,
      cfg
    );
    this.onSave(updated);
    this.controller?.close();
  }

  cancel(): void {
    this.controller?.close();
  }

  @Builder
  Label(text: string) {
    Text(text)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor('#666666')
      .margin({ top: 12, bottom: 6 })
  }

  build() {
    Column() {
      Text('编辑应用信息')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 4 })

      Text(`类型: ${this.app.type}    模式: ${this.app.runtimeMode}`)
        .fontSize(11)
        .fontColor('#999999')

      Scroll() {
        Column() {
          this.Label('应用名称')
          TextInput({ text: this.editName })
            .height(36)
            .fontSize(13)
            .onChange((v: string): void => { this.editName = v; })

          this.Label('应用图标 (Emoji)')
          TextInput({ text: this.editIcon })
            .height(36)
            .width(120)
            .fontSize(16)
            .onChange((v: string): void => { this.editIcon = v; })

          this.Label('环境变量')
          TextArea({
            placeholder: 'KEY=VALUE, 多行或用 ; 分隔\n占位符: ${APP_DIR}, ${X64_LIBS}, ${FILES_DIR}',
            text: this.editEnvVars
          })
            .height(96)
            .fontSize(13)
            .onChange((v: string): void => { this.editEnvVars = v; })

          this.Label('启动参数')
          TextInput({
            placeholder: '--debug --port=8080',
            text: this.editArgs
          })
            .height(36)
            .fontSize(13)
            .onChange((v: string): void => { this.editArgs = v; })

          this.Label('主可执行文件 (只读)')
          Text(this.app.execPath)
            .fontSize(12)
            .fontColor('#888888')
            .width('100%')

          this.Label('沙箱目录 (只读)')
          Text(this.app.installDir)
            .fontSize(11)
            .fontColor('#888888')
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .margin({ top: 8 })

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick((): void => { this.cancel(); })
        Button('保存')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .backgroundColor(Theme.HM_BLUE)
          .onClick((): void => { this.doSave(); })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('92%')
    .constraintSize({ maxHeight: '85%' })
    .padding(20)
    .backgroundColor(Color.White)
    .borderRadius(12)
  }
}