// OH KeyCode (@ohos.multimodalInput.keyCode) → Linux evdev 码
// evdev 表参考: include/uapi/linux/input-event-codes.h
export const OH2EVDEV: Record<number, number> = {
  // 数字行 0-9 (KEYCODE_0..9 = 2000..2009)
  2000: 11, 2001: 2,  2002: 3,  2003: 4,  2004: 5,
  2005: 6,  2006: 7,  2007: 8,  2008: 9,  2009: 10,

  // 方向键 (DPAD_UP/DOWN/LEFT/RIGHT = 2012..2015)
  2012: 103, 2013: 108, 2014: 105, 2015: 106,

  // 字母 A-Z (KEYCODE_A..Z = 2017..2042)
  2017: 30, 2018: 48, 2019: 46, 2020: 32, 2021: 18,
  2022: 33, 2023: 34, 2024: 35, 2025: 23, 2026: 36,
  2027: 37, 2028: 38, 2029: 50, 2030: 49, 2031: 24,
  2032: 25, 2033: 16, 2034: 19, 2035: 31, 2036: 20,
  2037: 22, 2038: 47, 2039: 17, 2040: 45, 2041: 21,
  2042: 44,

  // 标点 / 修饰键
  2043: 51,    // COMMA       ,
  2044: 52,    // PERIOD      .
  2045: 56,    // ALT_LEFT
  2046: 100,   // ALT_RIGHT
  2047: 42,    // SHIFT_LEFT
  2048: 54,    // SHIFT_RIGHT
  2049: 15,    // TAB
  2050: 57,    // SPACE
  2054: 28,    // ENTER
  2055: 14,    // DEL (Backspace)
  2056: 41,    // GRAVE       `
  2057: 12,    // MINUS       -
  2058: 13,    // EQUALS      =
  2059: 26,    // LEFT_BRACKET  [
  2060: 27,    // RIGHT_BRACKET ]
  2061: 43,    // BACKSLASH   \
  2062: 39,    // SEMICOLON   ;
  2063: 40,    // APOSTROPHE  '
  2064: 53,    // SLASH       /

  // 导航
  2068: 104,   // PAGE_UP
  2069: 109,   // PAGE_DOWN
  2070: 1,     // ESCAPE
  2071: 111,   // FORWARD_DEL (Delete)
  2081: 102,   // MOVE_HOME
  2082: 107,   // MOVE_END
  2083: 110,   // INSERT

  // 控制
  2072: 29,    // CTRL_LEFT
  2073: 97,    // CTRL_RIGHT
  2074: 58,    // CAPS_LOCK
  2076: 125,   // META_LEFT
  2077: 126,   // META_RIGHT

  // 功能键
  2090: 59,  2091: 60,  2092: 61,  2093: 62,
  2094: 63,  2095: 64,  2096: 65,  2097: 66,
  2098: 67,  2099: 68,  2100: 87,  2101: 88,
  2102: 69,    // NUM_LOCK
};

// 修饰键位掩码 (xkb 标准)
export const MOD_SHIFT: number = 1 << 0;
export const MOD_CAPS:  number = 1 << 1;
export const MOD_CTRL:  number = 1 << 2;
export const MOD_ALT:   number = 1 << 3;
export const MOD_NUM:   number = 1 << 4;
export const MOD_SUPER: number = 1 << 6;

export function modMaskOf(ohKeyCode: number): number {
  if (ohKeyCode === 2047 || ohKeyCode === 2048) return MOD_SHIFT;  // SHIFT_L/R
  if (ohKeyCode === 2072 || ohKeyCode === 2073) return MOD_CTRL;   // CTRL_L/R
  if (ohKeyCode === 2045 || ohKeyCode === 2046) return MOD_ALT;    // ALT_L/R
  return 0;
}