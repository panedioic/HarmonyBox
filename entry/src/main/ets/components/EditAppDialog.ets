import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import {
  AppInfo, AppConfig, RuntimeMode, ExecPathType,
  execPathTypeLabel, execPathTypeHint
} from '../model/AppInfo';
import { ContainerInfo, ContainerType } from '../model/ContainerInfo';
import { ContainerService } from '../service/ContainerService';

@CustomDialog
export struct EditAppDialog {
  controller?: CustomDialogController;
  app: AppInfo = new AppInfo();
  onSave: (updated: AppInfo) => void = () => {};

  @State editName: string = '';
  @State editIcon: string = '📦';
  @State editExec: string = '';
  @State editExecPathType: ExecPathType = ExecPathType.APP_RELATIVE;
  @State editMode: RuntimeMode = RuntimeMode.GUI;
  @State editArgs: string = '';
  @State editEnvVars: string = '';
  @State editContainerId: string = '';

  @State containers: ContainerInfo[] = [];

  private allModes: RuntimeMode[] = [RuntimeMode.GUI, RuntimeMode.CLI];
  private allPathTypes: ExecPathType[] = [
    ExecPathType.APP_RELATIVE,
    ExecPathType.CONTAINER_RELATIVE,
    ExecPathType.ABSOLUTE,
    ExecPathType.BARE
  ];

  aboutToAppear(): void {
    this.editName         = this.app.name;
    this.editIcon         = this.app.icon || '📦';
    this.editExec         = this.app.execPath;
    this.editExecPathType = this.app.execPathType || ExecPathType.APP_RELATIVE;
    this.editMode         = this.app.runtimeMode;
    this.editEnvVars      = this.app.config.envVars || '';
    this.editArgs         = this.app.config.args || '';
    this.editContainerId  = this.app.containerId || '';

    const ctx = getContext(this) as common.Context;
    this.containers = ContainerService.list(ctx);
  }

  private doSave(): void {
    const cfg: AppConfig = {
      envVars: this.editEnvVars,
      args:    this.editArgs
    };
    const updated: AppInfo = new AppInfo(
      this.app.id,
      this.editName.trim() || this.app.name,
      this.editIcon || '📦',
      this.app.type,
      this.editMode,
      this.editExec.trim() || this.app.execPath,
      this.editExecPathType,
      this.app.installDir,
      this.app.installedAt,
      cfg,
      this.editContainerId
    );
    this.onSave(updated);
    this.controller?.close();
  }

  private cancel(): void {
    this.controller?.close();
  }

  private formatInstalledAt(ts: number): string {
    if (!ts) return '(未知)';
    const d = new Date(ts);
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} `
      + `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  @Builder
  Label(text: string) {
    Text(text)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.TEXT_SEC)
      .margin({ top: 14, bottom: 6 })
  }

  @Builder
  ReadonlyRow(k: string, v: string) {
    Row({ space: 6 }) {
      Text(k).fontSize(11).fontColor(Theme.TEXT_HINT).width(80)
      Text(v).fontSize(12).fontColor(Theme.TEXT_MAIN)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  ModeChips() {
    Row({ space: 8 }) {
      ForEach(this.allModes, (m: RuntimeMode): void => {
        Text(m === RuntimeMode.GUI ? '图形界面' : '命令行')
          .fontSize(12)
          .fontColor(this.editMode === m ? Color.White : Theme.TEXT_MAIN)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor(this.editMode === m ? Theme.HM_BLUE : '#F0F0F0')
          .borderRadius(8)
          .onClick((): void => { this.editMode = m; })
      }, (m: RuntimeMode): string => m)
    }
  }

  @Builder
  ExecPathTypeChips() {
    Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
      ForEach(this.allPathTypes, (t: ExecPathType): void => {
        Text(execPathTypeLabel(t))
          .fontSize(11)
          .fontColor(this.editExecPathType === t ? Color.White : Theme.TEXT_MAIN)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.editExecPathType === t ? Theme.HM_BLUE : '#F0F0F0')
          .borderRadius(6)
          .margin({ right: 6, bottom: 6 })
          .onClick((): void => { this.editExecPathType = t; })
      }, (t: ExecPathType): string => t)
    }
    .width('100%')
  }

  @Builder
  ContainerChips() {
    if (this.containers.length === 0) {
      Row({ space: 8 }) {
        Text('⚠️').fontSize(14)
        Text('尚未安装任何容器').fontSize(12).fontColor('#E64545')
      }
      .width('100%').padding(10)
      .backgroundColor('#FEF2F2').borderRadius(8)
    } else {
      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
        ForEach(this.containers, (c: ContainerInfo): void => {
          Row({ space: 6 }) {
            Text(c.config.type === ContainerType.WINE ? '🍷' : '🐧')
              .fontSize(14)
            Text(c.config.name).fontSize(12)
              .fontColor(this.editContainerId === c.id
                ? Color.White : Theme.TEXT_MAIN)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .borderRadius(8)
          .backgroundColor(this.editContainerId === c.id
            ? Theme.HM_BLUE : '#F0F0F0')
          .margin({ right: 8, bottom: 8 })
          .onClick((): void => { this.editContainerId = c.id; })
        }, (c: ContainerInfo): string => c.id)
      }
      .width('100%')
    }
  }

  build() {
    Column() {
      // header
      Row() {
        Text('编辑应用').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_MAIN).layoutWeight(1)
        Text('✕').fontSize(16).fontColor(Theme.TEXT_HINT)
          .padding(6)
          .onClick((): void => { this.cancel(); })
      }
      .width('100%').height(48)
      .padding({ left: 20, right: 12 })
      .border({ width: { bottom: 1 }, color: Theme.BORDER_LIGHT })

      // body
      Scroll() {
        Column() {
          // 基本信息
          this.Label('应用名称')
          TextInput({ placeholder: '显示名称', text: this.editName })
            .height(36).fontSize(13).width('100%')
            .onChange((v: string): void => { this.editName = v; })

          Row({ space: 12 }) {
            Column() {
              this.Label('图标 (Emoji)')
              TextInput({ placeholder: '📦', text: this.editIcon })
                .height(36).width(90).fontSize(16)
                .onChange((v: string): void => { this.editIcon = v; })
            }.alignItems(HorizontalAlign.Start)

            Column() {
              this.Label('运行模式')
              this.ModeChips()
            }.alignItems(HorizontalAlign.Start)
          }
          .width('100%')

          Divider().color(Theme.BORDER_LIGHT).margin({ top: 16 })

          // 运行配置
          this.Label('主可执行文件')
          TextInput({ placeholder: 'bin/app / notepad / /system/bin/sh', text: this.editExec })
            .height(36).fontSize(13).width('100%')
            .onChange((v: string): void => { this.editExec = v; })

          this.Label('路径类型')
          this.ExecPathTypeChips()
          Text(execPathTypeHint(this.editExecPathType))
            .fontSize(11).fontColor(Theme.TEXT_HINT).margin({ top: 2 })

          this.Label('启动参数')
          TextInput({ placeholder: '--debug --port=8080', text: this.editArgs })
            .height(36).fontSize(13).width('100%')
            .onChange((v: string): void => { this.editArgs = v; })

          this.Label('环境变量')
          TextArea({
            placeholder: 'KEY=VALUE (每行一个)\n可用: ${APP_DIR}, ${X64_LIBS}, ${FILES_DIR}',
            text: this.editEnvVars
          })
            .height(90).fontSize(12).width('100%')
            .onChange((v: string): void => { this.editEnvVars = v; })

          Divider().color(Theme.BORDER_LIGHT).margin({ top: 16 })

          // 容器绑定
          this.Label('运行容器')
          this.ContainerChips()

          Divider().color(Theme.BORDER_LIGHT).margin({ top: 16 })

          // 只读信息
          this.Label('系统信息')
          Column({ space: 6 }) {
            this.ReadonlyRow('应用 ID',   this.app.id)
            this.ReadonlyRow('沙箱目录', this.app.installDir)
            this.ReadonlyRow('安装时间', this.formatInstalledAt(this.app.installedAt))
          }
          .width('100%')
          .padding(12)
          .backgroundColor('#F5F7FA')
          .borderRadius(8)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding(20)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Auto)

      // footer
      Row({ space: 12 }) {
        Blank()
        Button('取消')
          .fontSize(13).height(36).width(90)
          .backgroundColor('#F0F0F0').fontColor(Theme.TEXT_MAIN)
          .onClick((): void => { this.cancel(); })
        Button('保存')
          .fontSize(13).height(36).width(120)
          .backgroundColor(Theme.HM_BLUE)
          .onClick((): void => { this.doSave(); })
      }
      .width('100%').height(60)
      .padding({ left: 20, right: 20 })
      .backgroundColor('#FAFBFC')
      .border({ width: { top: 1 }, color: Theme.BORDER_LIGHT })
    }
    .width(640).height(600)
    .backgroundColor(Theme.HM_CARD)
    .borderRadius(Theme.RADIUS_LG)
    .clip(true)
  }
}