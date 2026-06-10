import { Theme } from '../common/Theme';

@Component
export struct SettingsPage {
  @State winVersion: number = 1; // 0:11, 1:10, 2:7
  @State dpi: number = 96;
  @State vulkanEnabled: boolean = true;

  private winOptions: string[] = ['Windows 11', 'Windows 10', 'Windows 7'];

  build() {
    Column() {
      Text('全局 Wine 配置')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 20 })

      Column({ space: 20 }) {
        // Windows 版本
        Row() {
          Text('Windows 版本：').fontSize(15).fontWeight(FontWeight.Bold)
          Select(this.winOptions.map(o => ({ value: o } as SelectOption)))
            .selected(this.winVersion)
            .value(this.winOptions[this.winVersion])
            .onSelect((index: number) => {
              this.winVersion = index;
            })
        }
        .width('100%')

        // DPI
        Row({ space: 12 }) {
          Text('DPI 缩放：').fontSize(15).fontWeight(FontWeight.Bold)
          Slider({
            value: this.dpi,
            min: 96,
            max: 192,
            step: 1,
            style: SliderStyle.OutSet
          })
            .blockColor(Theme.HM_BLUE)
            .selectedColor(Theme.HM_BLUE)
            .layoutWeight(1)
            .onChange((value: number) => {
              this.dpi = Math.round(value);
            })
          Text(`${this.dpi} DPI`).fontSize(14).fontColor(Theme.TEXT_SECONDARY)
        }
        .width('100%')

        // Vulkan
        Row({ space: 12 }) {
          Text('图形加速：').fontSize(15).fontWeight(FontWeight.Bold)
          Toggle({ type: ToggleType.Switch, isOn: this.vulkanEnabled })
            .selectedColor(Theme.HM_BLUE)
            .onChange((isOn: boolean) => {
              this.vulkanEnabled = isOn;
            })
          Text('开启 Vulkan (DXVK) 支持').fontSize(14).fontColor(Theme.TEXT_SECONDARY)
        }
        .width('100%')
      }
      .width('100%')
      .padding(25)
      .backgroundColor(Color.White)
      .borderRadius(Theme.RADIUS)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}