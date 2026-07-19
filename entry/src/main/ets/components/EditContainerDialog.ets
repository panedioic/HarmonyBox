import { Theme } from '../common/Theme';
import { ContainerInfo, ContainerType, containerTypeLabel } from '../model/ContainerInfo';
import { ContainerService } from '../service/ContainerService';

@CustomDialog
export struct EditContainerDialog {
  controller?: CustomDialogController;
  info: ContainerInfo = {} as ContainerInfo;
  onSaved: (info: ContainerInfo) => void = () => {};

  @State cName: string = '';
  @State cDescription: string = '';
  @State cEnvText: string = '';        // 多行 KEY=VAL
  @State saving: boolean = false;
  @State status: string = '';

  aboutToAppear(): void {
    this.cName        = this.info.config.name;
    this.cDescription = this.info.config.description;
    this.cEnvText     = (this.info.config.envVars || []).join('\n');
  }

  private canSave(): boolean {
    if (this.saving) return false;
    if (!this.cName.trim()) return false;
    return true;
  }

  /** 解析多行文本 -> 规范化的 KEY=VAL 数组 */
  private parseEnv(text: string): string[] {
    const out: string[] = [];
    const lines: string[] = text.split('\n');
    for (const raw of lines) {
      const t: string = raw.trim();
      if (t.length === 0) continue;
      if (t.startsWith('#')) continue;
      const eq: number = t.indexOf('=');
      if (eq <= 0) continue;                    // 必须有 =, 且 key 非空
      out.push(t);
    }
    return out;
  }

  private doSave(): void {
    this.saving = true;
    this.status = '保存中...';
    try {
      this.info.config.name        = this.cName.trim();
      this.info.config.description = this.cDescription.trim();
      this.info.config.envVars     = this.parseEnv(this.cEnvText);

      const ok: boolean = ContainerService.writeConfig(this.info.path, this.info.config);
      if (!ok) {
        this.status = '保存失败: 写入 container.json 失败';
        this.saving = false;
        return;
      }
      this.status = '保存完成';
      setTimeout((): void => {
        this.saving = false;                 // ★ 补上, 万一 close 又抽风也不会卡按钮
        this.onSaved(this.info);
        this.controller?.close();
      }, 400);
    } catch (e) {
      this.status = '保存异常: ' + (e as Error).message;
      this.saving = false;
    }
  }

  build() {
    Column() {
      // header
      Row() {
        Text('编辑容器').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_MAIN).layoutWeight(1)
        Text('✕').fontSize(16).fontColor(Theme.TEXT_HINT)
          .padding(6)
          .onClick((): void => { this.controller?.close(); })
      }
      .width('100%').height(48)
      .padding({ left: 20, right: 12 })
      .border({ width: { bottom: 1 }, color: Theme.BORDER_LIGHT })

      // body
      Scroll() {
        Column() {
          // 只读摘要卡
          Row({ space: 10 }) {
            Text(this.info.config.type === ContainerType.WINE ? '🍷' : '🐧')
              .fontSize(22)
            Column() {
              Text(this.info.id).fontSize(13).fontColor(Theme.TEXT_MAIN)
                .fontWeight(FontWeight.Medium)
              Text(`${containerTypeLabel(this.info.config.type)} · ${this.info.config.arch}`
                + (this.info.config.version ? ` · ${this.info.config.version}` : ''))
                .fontSize(11).fontColor(Theme.TEXT_HINT).margin({ top: 2 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }
          .width('100%').padding(12)
          .backgroundColor('#F5F7FA').borderRadius(8)
          .margin({ bottom: 12 })

          // 运行中提示
          if (this.info.running) {
            Row({ space: 6 }) {
              Text('⚠️').fontSize(12)
              Text('容器当前运行中, 环境变量修改将在下次启动时生效')
                .fontSize(11).fontColor('#B76E00').layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor('#FFF4E5').borderRadius(6)
            .margin({ bottom: 12 })
          }

          // 名称
          Text('名称 *').fontSize(12).fontColor(Theme.TEXT_SEC)
            .fontWeight(FontWeight.Medium).margin({ bottom: 6 })
          TextInput({ text: this.cName })
            .height(36).fontSize(13).width('100%')
            .onChange((v: string): void => { this.cName = v; })

          // 描述
          Text('描述').fontSize(12).fontColor(Theme.TEXT_SEC)
            .fontWeight(FontWeight.Medium).margin({ top: 14, bottom: 6 })
          TextArea({ text: this.cDescription, placeholder: '(可选)' })
            .height(60).fontSize(12).width('100%')
            .onChange((v: string): void => { this.cDescription = v; })

          // 环境变量
          Text('环境变量').fontSize(12).fontColor(Theme.TEXT_SEC)
            .fontWeight(FontWeight.Medium).margin({ top: 14, bottom: 6 })
          Text('每行一条, 格式 KEY=VALUE. 以 # 开头或格式错误的行会被忽略')
            .fontSize(11).fontColor(Theme.TEXT_HINT).margin({ bottom: 6 })
          TextArea({
            text: this.cEnvText,
            placeholder: 'WINEDEBUG=-all\nWINEPREFIX=/path/to/prefix'
          })
            .height(200).fontSize(11).width('100%')
            .fontFamily('monospace')
            .onChange((v: string): void => { this.cEnvText = v; })
        }
        .width('100%').padding(20)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1).width('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Auto)

      // footer
      Row({ space: 12 }) {
        if (this.status.length > 0) {
          Text(this.status).fontSize(12)
            .fontColor(this.status.startsWith('保存失败')
              || this.status.startsWith('保存异常')
              ? '#E64545' : Theme.TEXT_SEC)
            .layoutWeight(1)
        } else {
          Blank()
        }
        Button('取消')
          .fontSize(13).height(36).width(90)
          .backgroundColor('#F0F0F0').fontColor(Theme.TEXT_MAIN)
          .onClick((): void => { this.controller?.close(); })
        Button(this.saving ? '保存中...' : '保存')
          .fontSize(13).height(36).width(120)
          .backgroundColor(this.canSave() ? Theme.HM_BLUE : '#B0B7C0')
          .enabled(this.canSave())
          .onClick((): void => { this.doSave(); })
      }
      .width('100%').height(60)
      .padding({ left: 20, right: 20 })
      .backgroundColor('#FAFBFC')
      .border({ width: { top: 1 }, color: Theme.BORDER_LIGHT })
    }
    .width('94%').height('90%')
    .constraintSize({ maxWidth: 600, maxHeight: 560 })
    .backgroundColor(Theme.HM_CARD)
    .borderRadius(Theme.RADIUS_LG)
    .clip(true)
  }
}