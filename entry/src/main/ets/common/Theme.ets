// entry/src/main/ets/common/Theme.ets
export class Theme {
  static readonly HM_BLUE:     string = '#007DFF';
  static readonly HM_BLUE_SOFT:string = '#E6F1FF';   // 选中背景
  static readonly HM_BG:       string = '#F5F7FA';   // 页面底色
  static readonly HM_CARD:     string = '#FFFFFF';   // 卡片/面板底色
  static readonly BORDER_LIGHT:string = '#EDEFF2';
  static readonly TEXT_MAIN:   string = '#1F2329';
  static readonly TEXT_SEC:    string = '#5C6470';
  static readonly TEXT_HINT:   string = '#A3A9B3';
  static readonly RADIUS:      number = 12;
  static readonly RADIUS_LG:   number = 16;
}

export class PageType {
  static readonly LIBRARY:       string = 'library';
  static readonly INSTALL:       string = 'install';
  static readonly SETTINGS:      string = 'settings';
  static readonly FILES:         string = 'files';
  static readonly PROC_MANAGER:  string = 'proc_manager';
  static readonly DEBUG_SHELL:   string = 'debug_shell';
  static readonly DEBUG:         string = 'debug';
}