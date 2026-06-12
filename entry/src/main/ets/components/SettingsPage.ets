import { common, Want } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { ToolDetector, ToolStatus } from '../service/ToolDetector';
import { ToolEnvStore, Box64Env } from '../model/ToolEnvStore';

@Component
export struct SettingsPage {
  @State tools: ToolStatus[] = [];
  @State hapsHowto: ToolStatus = ToolDetector.getHapsHowto();
  @State box64Env: Box64Env = ToolEnvStore.defaults();
  @State savedHint: string = '';

  aboutToAppear(): void {
    this.refreshTools();
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.box64Env = ToolEnvStore.loadBox64(ctx);
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