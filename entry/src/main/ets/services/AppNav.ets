/**
 * HPVPlayer - 全局导航栈（Navigation 路由）+ Tab 切换信号。
 *
 * 首页 Navigation(appNav) 挂载；各处通过 appNav.pushPath /
 * appNav.pop 导航。路由名: PlayerPage(router) / WebDavPage /
 * DetailPage。
 */
export const appNav: NavPathStack = new NavPathStack();

export class NavRoutes {
  static readonly PLAYER = 'PlayerPage';
  static readonly WEBDAV = 'WebDavPage';
  static readonly DETAIL = 'DetailPage';
  static readonly CONFIG_BROWSER = 'ConfigBrowserPage';
}

/** WebDavPage 浏览参数 */
export interface WebDavBrowseParam {
  sourceId: string;
}

/** Tab 切换事件：媒体库/资源库/设置页之间跳转（emit 形式，无 payload） */
class TabSignal {
  private listeners: Array<(tab: number) => void> = [];

  on(listener: (tab: number) => void): void {
    this.listeners.push(listener);
  }

  emit(tab: number): void {
    for (const l of this.listeners) {
      l(tab);
    }
  }
}

export const tabSignal: TabSignal = new TabSignal();

/** 媒体库数据变更信号（刮削/手动匹配后通知海报墙刷新） */
class LibraryDirtySignal {
  private listeners: Array<() => void> = [];

  on(listener: () => void): void {
    this.listeners.push(listener);
  }

  emit(): void {
    for (const l of this.listeners) {
      l();
    }
  }
}

export const libraryDirty: LibraryDirtySignal = new LibraryDirtySignal();

/** Tab 索引约定 */
export class TabIndex {
  static readonly LIBRARY = 0;
  static readonly SOURCES = 1;
  static readonly SETTINGS = 2;
}
