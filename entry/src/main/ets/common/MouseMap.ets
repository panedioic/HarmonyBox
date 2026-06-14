// Linux input-event-codes.h
export const BTN_LEFT:   number = 0x110;
export const BTN_RIGHT:  number = 0x111;
export const BTN_MIDDLE: number = 0x112;
export const BTN_BACK:   number = 0x116;
export const BTN_FORWARD:number = 0x115;

// ArkUI MouseButton enum: Left=1, Right=2, Middle=4, Back=8, Forward=16
export function mapMouseButton(b: number): number {
  switch (b) {
    case 1:  return BTN_LEFT;
    case 2:  return BTN_RIGHT;
    case 4:  return BTN_MIDDLE;
    case 8:  return BTN_BACK;
    case 16: return BTN_FORWARD;
    default: return BTN_LEFT;
  }
}