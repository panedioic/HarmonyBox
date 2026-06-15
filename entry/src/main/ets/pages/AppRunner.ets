import wl from 'libentry.so';
import { OH2EVDEV, modMaskOf, MOD_SHIFT, MOD_CTRL, MOD_ALT } from '../common/KeyMap';
import { mapMouseButton } from '../common/MouseMap';
import { WaylandService } from '../service/WaylandService';

@Entry
@Component
struct AppRunner {
  @State appName: string = '应用';
  @State surfaceW: number = 800;
  @State surfaceH: number = 600;
  @State scaleNumber: number = 1.0;

  // ArkTS 自己维护修饰键状态
  private modMask: number = 0;

  aboutToAppear(): void {
    const name = AppStorage.get<string>('currentAppName');
    if (name) this.appName = name;
    this.scaleNumber = WaylandService.getInstance().getUiScale();
  }

  private updateModifiers(ohKey: number, pressed: boolean): void {
    const mask: number = modMaskOf(ohKey);
    if (mask === 0) return;
    if (pressed) this.modMask |= mask;
    else this.modMask &= ~mask;
    wl.sendModifiers(this.modMask, 0, 0, 0);
  }

  build() {
    Stack() {
      XComponent({
        id: 'wl_xc',
        type: XComponentType.SURFACE,
        libraryname: 'entry'
      })
        .width('100%').height('100%')
        .onLoad((): void => {
          // 通知一次进入
          wl.sendMouseHover(true);
        })
    }
    .width('100%').height('100%')
    .backgroundColor(Color.Black)
    // ── 焦点 ──
    .focusable(true)
    .defaultFocus(true)
    // ── 键盘 ──
    .onKeyEvent((ev: KeyEvent): void => {
      const code: number = OH2EVDEV[ev.keyCode] ?? 0;
      if (code === 0) return;
      const pressed: boolean = ev.type === KeyType.Down;
      // 修饰键先发 modifiers,再发 key
      this.updateModifiers(ev.keyCode, pressed);
      wl.sendKey(code, pressed);
    })
    // ── 鼠标 ──
    .onMouse((ev: MouseEvent): void => {
      // host 窗口被放大了 scale 倍,所以 px 要除回 buffer 坐标系
      const s: number = this.scaleNumber > 0 ? this.scaleNumber : 1.0;
      const x: number = vp2px(ev.x) / s;
      const y: number = vp2px(ev.y) / s;
      switch (ev.action) {
        case MouseAction.Move:
        case MouseAction.Hover:
          wl.sendMouseMove(x, y);
          break;
        case MouseAction.Press:
          wl.sendMouseMove(x, y);
          wl.sendMouseButton(mapMouseButton(ev.button), true);
          break;
        case MouseAction.Release:
          wl.sendMouseButton(mapMouseButton(ev.button), false);
          break;
        default:
          break;
      }
    })
    .onHover((isHover: boolean): void => {
      wl.sendMouseHover(isHover);
    })
  }
}