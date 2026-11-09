/**
 * HPVPlayer - 主页：底部三 Tab（媒体库 / 资源库 / 设置）。
 * Tab 间内容互斥；二级页（详情 / WebDAV）走 Navigation 压栈；
 * 播放器为独立 router 全屏页。
 */
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { LibraryTab } from '../components/LibraryTab';
import { SourcesTab } from '../components/SourcesTab';
import { SettingsTab } from '../components/SettingsTab';
import { appNav, NavRoutes, tabSignal } from '../services/AppNav';
import { DetailPage } from './DetailPage';
import { WebDavPage } from './WebDavPage';

interface TabSymbolStyle {
  normal: SymbolGlyphModifier;
  selected: SymbolGlyphModifier;
}

function makeTabSymbol(icon: Resource): TabSymbolStyle {
  return {
    normal: new SymbolGlyphModifier(icon)
      .fontColor([$r('app.color.text_secondary')]),
    selected: new SymbolGlyphModifier(icon)
      .fontColor([$r('app.color.brand')]),
  };
}

@Entry
@ComponentV2
struct Index {
  @Local currentTab: number = 0;
  private tabsController: TabsController = new TabsController();
  private signalHooked: boolean = false;

  aboutToAppear(): void {
    if (!this.signalHooked) {
      this.signalHooked = true;
      tabSignal.on((tab: number) => {
        this.currentTab = tab;
        this.tabsController.changeIndex(tab);
      });
    }
  }

  @Builder
  pagesMap(name: string) {
    if (name === NavRoutes.WEBDAV) {
      WebDavPage()
    } else if (name === NavRoutes.DETAIL) {
      DetailPage()
    }
  }

  build() {
    Navigation(appNav) {
      Tabs({ barPosition: BarPosition.End, index: this.currentTab,
        controller: this.tabsController }) {
        TabContent() {
          LibraryTab()
        }
        .tabBar(BottomTabBarStyle.of(makeTabSymbol($r('sys.symbol.rectangle_stack')), '媒体库'))

        TabContent() {
          SourcesTab()
        }
        .tabBar(BottomTabBarStyle.of(makeTabSymbol($r('sys.symbol.externaldrive_fill')), '资源库'))

        TabContent() {
          SettingsTab()
        }
        .tabBar(BottomTabBarStyle.of(makeTabSymbol($r('sys.symbol.gearshape')), '设置'))
      }
      .barMode(BarMode.Fixed)
      .scrollable(false)
      .onChange((index: number) => {
        this.currentTab = index;
      })
      .width('100%')
      .height('100%')
    }
    .navDestination(this.pagesMap)
    .mode(NavigationMode.Stack)
    .title('HPVPlayer')
    .hideTitleBar(this.currentTab !== 0)
    .backgroundColor($r('app.color.page_background'))
  }
}
