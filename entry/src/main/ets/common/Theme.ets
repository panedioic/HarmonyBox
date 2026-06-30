export class Theme {
  static readonly HM_BLUE: string = '#007DFF';
  static readonly HM_BG: string = '#F1F3F5';
  static readonly HM_CARD: string = '#FFFFFF';
  static readonly TEXT_PRIMARY: string = '#000000';
  static readonly TEXT_SECONDARY: string = '#99000000';
  static readonly TEXT_HINT: string = '#999999';
  static readonly BORDER_LIGHT: string = '#0D000000';
  static readonly RADIUS: number = 16;
  static readonly RADIUS_NAV: number = 10;
  static readonly SIDEBAR_WIDTH: number = 200;  // 240 → 200
}

export enum PageType {
  LIBRARY = 'library',
  INSTALL = 'install',
  SETTINGS = 'settings',
  FILES = 'files',
  DEBUG = 'debug',
  PROC_MANAGER = 'PROC_MANAGER',
  DEBUG_SHELL = 'debug_shell'
}