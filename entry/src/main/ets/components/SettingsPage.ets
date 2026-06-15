import { common, Want } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { ToolDetector, ToolStatus } from '../service/ToolDetector';
import { ToolEnvStore, Box64Env, UiPrefs } from '../model/ToolEnvStore';
import { LibStore, LibFile } from '../service/LibStore';
import { WaylandService } from '../service/WaylandService';

@Component
export struct SettingsPage {
  @State tools: ToolStatus[] = [];
  @State hapsHowto: ToolStatus = ToolDetector.getHapsHowto();
  @State box64Env: Box64Env = ToolEnvStore.defaults();
  @State savedHint: string = '';
  @State libFiles: LibFile[] = [];
  @State libDir: string = '';
  @State uiScale: number = 1.0;

  private scaleOptions: number[] = [1.0, 1.25, 1.5, 2.0, 3.0];

  aboutToAppear(): void {
    this.refreshTools();
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.box64Env = ToolEnvStore.loadBox64(ctx);
    this.refreshLibs();
    const uiPrefs: UiPrefs = ToolEnvStore.loadUiPrefs(ctx);
    this.uiScale = uiPrefs.scale;
  }

  refreshTools(): void {
    const list: ToolStatus[] = ToolDetector.probeAll();
    this.tools = list;
    this.fetchAllVersions();
  }

  async fetchAllVersions(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const specs = ToolDetector.getSpecs();
    for (let i = 0; i < this.tools.length; i++) {
      const t: ToolStatus = this.tools[i];
      if (!t.installed) continue;
      const spec = specs[i];
      const ver: string = await ToolDetector.fetchVersion(ctx, spec, t.path);
      // 触发 UI 更新需要重建数组
      const next: ToolStatus[] = this.tools.slice();
      next[i] = {
        id: t.id, name: t.name, url: t.url,
        installed: t.installed, path: t.path,
        version: ver
      } as ToolStatus;
      this.tools = next;
    }
  }

  openUrl(url: string): void {
    if (!url) return;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url,
        entities: ['entity.system.browsable']
      };
      ctx.startAbility(want);
    } catch (e) {
      console.error(`openUrl failed: ${JSON.stringify(e)}`);
    }
  }

  saveBox64Env(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ToolEnvStore.saveBox64(ctx, this.box64Env);
    this.savedHint = '已保存(尚未在 cpp 侧生效)';
    setTimeout((): void => { this.savedHint = ''; }, 2000);
  }

  resetBox64Env(): void {
    this.box64Env = ToolEnvStore.defaults();
  }

  refreshLibs(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.libDir = LibStore.getDir(ctx);
    this.libFiles = LibStore.list(ctx);
  }

  async uploadLibs(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const n: number = await LibStore.pickAndAdd(ctx);
    if (n > 0) {
      this.refreshLibs();
      this.savedHint = `已添加 ${n} 个文件`;
      setTimeout((): void => { this.savedHint = ''; }, 2000);
    }
  }

  removeLib(name: string): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    LibStore.remove(ctx, name);
    this.refreshLibs();
  }

  clearLibs(): void {
    AlertDialog.show({
      title: '清空共享库',
      message: `将删除 ${this.libFiles.length} 个文件,无法撤销。`,
      primaryButton: {
        value: '取消', action: (): void => {}
      },
      secondaryButton: {
        value: '清空',
        fontColor: '#E64545',
        action: (): void => {
          const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
          LibStore.clear(ctx);
          this.refreshLibs();
        }
      }
    });
  }

  @Builder
  ScaleChip(s: number) {
    Text(`${Math.round(s * 100)}%`)
      .fontSize(13)
      .fontColor(this.uiScale === s ? Color.White : '#333333')
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.uiScale === s ? Theme.HM_BLUE : '#F0F0F0')
      .borderRadius(8)
      .margin({ right: 10, bottom: 10 })
      .onClick((): void => {
        const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        this.uiScale = s;
        const prefs: UiPrefs = { scale: s } as UiPrefs;
        ToolEnvStore.saveUiPrefs(ctx, prefs);
        WaylandService.getInstance().reloadUiPrefs(ctx);
        this.savedHint = `已设置缩放 ${Math.round(s * 100)}%`;
        setTimeout((): void => { this.savedHint = ''; }, 2000);
      })
  }

  @Builder
  ToolRow(t: ToolStatus) {
    Column({ space: 6 }) {
      Row() {
        Text(t.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)

        Text(t.installed ? '已安装' : '未安装')
          .fontSize(12)
          .fontColor(t.installed ? '#1A8F4D' : '#999999')
          .backgroundColor(t.installed ? '#E6F7EE' : '#F0F0F0')
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(6)
      }
      .width('100%')

      if (t.installed) {
        Text(`版本: ${t.version}`)
          .fontSize(12)
          .fontColor('#666666')
          .width('100%')
        Text(`路径: ${t.path}`)
          .fontSize(11)
          .fontColor('#AAAAAA')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Row({ space: 8 }) {
        Text(t.url || '暂未实现')
          .fontSize(12)
          .fontColor(t.url ? Theme.HM_BLUE : '#999999')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick((): void => {
            if (t.url) this.openUrl(t.url);
          })
      }
      .width('100%')
    }
    .padding(14)
    .backgroundColor('#FAFAFA')
    .borderRadius(10)
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ bottom: 10 })
  }

  @Builder
  EnvRow(label: string, hint: string, value: string, onChange: (v: string) => void) {
    Column({ space: 6 }) {
      Row() {
        Text(label)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .layoutWeight(1)
        Text(hint)
          .fontSize(11)
          .fontColor('#999999')
      }
      .width('100%')

      TextInput({ text: value })
        .height(34)
        .fontSize(13)
        .onChange(onChange)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ bottom: 12 })
  }

  build() {
    Scroll() {
      Column() {
        Text('环境配置')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 8 })

        Text('此版本不包含 wine、box64、box86、elf-loader 等运行时,需要自行安装。')
          .fontSize(13)
          .fontColor('#666666')
          .margin({ bottom: 4 })

        Text('安装完成后回到本页查看探测结果。')
          .fontSize(12)
          .fontColor('#999999')
          .margin({ bottom: 16 })

        // —— 鸿蒙应用安装方法(独立提示卡) ——
        Column({ space: 6 }) {
          Text(this.hapsHowto.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#333333')

          Text(this.hapsHowto.url)
            .fontSize(12)
            .fontColor(Theme.HM_BLUE)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick((): void => { this.openUrl(this.hapsHowto.url); })
        }
        .padding(14)
        .backgroundColor('#EEF6FF')
        .borderRadius(10)
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ bottom: 16 })

        // —— 工具列表 ——
        Row() {
          Text('运行时工具')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
          Button('刷新')
            .fontSize(12)
            .height(28)
            .padding({ left: 14, right: 14 })
            .backgroundColor('#F0F0F0')
            .fontColor('#333333')
            .onClick((): void => { this.refreshTools(); })
        }
        .width('100%')
        .margin({ bottom: 10 })

        Column() {
          ForEach(this.tools, (t: ToolStatus): void => {
            this.ToolRow(t)
          }, (t: ToolStatus): string => `${t.id}_${t.installed}_${t.version}`)
        }
        .width('100%')

        // —— X86_64 共享库 ——
        Row() {
          Column({ space: 2 }) {
            Text('X86_64 共享库 (box64)')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
            Text('上传应用依赖的 x86_64 .so,启动时自动注入 BOX64_LD_LIBRARY_PATH')
              .fontSize(11)
              .fontColor('#999999')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button('上传')
            .fontSize(12)
            .height(28)
            .padding({ left: 14, right: 14 })
            .backgroundColor(Theme.HM_BLUE)
            .onClick((): void => { this.uploadLibs(); })
          Button('清空')
            .fontSize(12)
            .height(28)
            .margin({ left: 8 })
            .padding({ left: 14, right: 14 })
            .backgroundColor('#F0F0F0')
            .fontColor('#333333')
            .enabled(this.libFiles.length > 0)
            .onClick((): void => { this.clearLibs(); })
        }
        .width('100%')
        .margin({ top: 16, bottom: 8 })

        Column() {
          Text(this.libDir)
            .fontSize(11)
            .fontColor('#999999')
            .width('100%')
            .margin({ bottom: 10 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.libFiles.length === 0) {
            Text('尚未上传任何 .so 文件')
              .fontSize(13)
              .fontColor('#999999')
              .padding(12)
          } else {
            ForEach(this.libFiles, (f: LibFile): void => {
              Row() {
                Column({ space: 2 }) {
                  Text(f.name)
                    .fontSize(13)
                    .fontColor('#333333')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(LibStore.formatSize(f.size))
                    .fontSize(11)
                    .fontColor('#999999')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Button('删除')
                  .fontSize(11)
                  .height(26)
                  .padding({ left: 10, right: 10 })
                  .backgroundColor('#FFEEEE')
                  .fontColor('#E64545')
                  .onClick((): void => { this.removeLib(f.name); })
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
            }, (f: LibFile): string => `${f.name}_${f.size}`)
          }
        }
        .padding(14)
        .backgroundColor('#FAFAFA')
        .borderRadius(10)
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        // —— 窗口缩放 ——
        Text('窗口缩放')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .margin({ top: 16, bottom: 4 })

        Text('高分屏上窗口太小时使用。仅对新打开的应用窗口生效,需重新启动应用。')
          .fontSize(12)
          .fontColor('#999999')
          .margin({ bottom: 12 })

        Column() {
          Flex({
            direction: FlexDirection.Row,
            wrap: FlexWrap.Wrap,
            justifyContent: FlexAlign.Start
          }) {
            ForEach(this.scaleOptions, (s: number): void => {
              this.ScaleChip(s)
            }, (s: number): string => `scale_${s}`)
          }
          .width('100%')

          Text('放大原理:鸿蒙窗口尺寸 = buffer × 缩放比;EGL 在显示时双线性放大,文字会略糊。后续可加客户端原生缩放。')
            .fontSize(11)
            .fontColor('#AAAAAA')
            .margin({ top: 4 })
        }
        .padding(14)
        .backgroundColor('#FAFAFA')
        .borderRadius(10)
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        // —— box64 环境变量 ——
        Text('box64 环境变量')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .margin({ top: 16, bottom: 4 })

        Text('保存后仅写入本地配置,运行时尚未读取(后续接通)。')
          .fontSize(12)
          .fontColor('#999999')
          .margin({ bottom: 12 })

        Column() {
          this.EnvRow(
            'BOX64_LOG', '日志级别 0-3',
            this.box64Env.BOX64_LOG,
            (v: string): void => { this.box64Env.BOX64_LOG = v; }
          )
          this.EnvRow(
            'BOX64_NOBANNER', '隐藏启动横幅 0/1',
            this.box64Env.BOX64_NOBANNER,
            (v: string): void => { this.box64Env.BOX64_NOBANNER = v; }
          )
          this.EnvRow(
            'BOX64_DYNAREC', '启用动态重编译 0/1',
            this.box64Env.BOX64_DYNAREC,
            (v: string): void => { this.box64Env.BOX64_DYNAREC = v; }
          )
          this.EnvRow(
            'BOX64_LD_LIBRARY_PATH', 'x86_64 共享库目录',
            this.box64Env.BOX64_LD_LIBRARY_PATH,
            (v: string): void => { this.box64Env.BOX64_LD_LIBRARY_PATH = v; }
          )

          // 自定义 env
          Column({ space: 6 }) {
            Text('自定义环境变量')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .width('100%')
            Text('每行 KEY=VALUE')
              .fontSize(11)
              .fontColor('#999999')
              .width('100%')
            TextArea({ text: this.box64Env.customEnv })
              .height(96)
              .fontSize(13)
              .onChange((v: string): void => { this.box64Env.customEnv = v; })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .margin({ bottom: 12 })

          Row({ space: 12 }) {
            Button('保存')
              .layoutWeight(1)
              .height(40)
              .fontSize(14)
              .backgroundColor(Theme.HM_BLUE)
              .onClick((): void => { this.saveBox64Env(); })
            Button('恢复默认')
              .layoutWeight(1)
              .height(40)
              .fontSize(14)
              .backgroundColor('#F0F0F0')
              .fontColor('#333333')
              .onClick((): void => { this.resetBox64Env(); })
          }
          .width('100%')

          if (this.savedHint.length > 0) {
            Text(this.savedHint)
              .fontSize(12)
              .fontColor('#1A8F4D')
              .margin({ top: 8 })
          }
        }
        .padding(14)
        .backgroundColor('#FAFAFA')
        .borderRadius(10)
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
  }
}