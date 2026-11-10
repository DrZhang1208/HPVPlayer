/**
 * HPVPlayer - 配置管理器（文件管理器风格，HarmonyOS 规范）。
 * List + ListItem 分组卡片；左滑显示重命名/删除；点击进入目录或编辑文件。
 */
import { common } from '@kit.AbilityKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import {
  ConfigFileEntry, MpvConfigManager
} from '../services/MpvConfigManager';
import { appNav, NavRoutes } from '../services/AppNav';

interface Breadcrumb {
  name: string;
  rel: string;
}

function formatSize(size: number): string {
  if (size <= 0) {
    return '';
  }
  if (size < 1024) {
    return `${size} B`;
  }
  if (size < 1024 * 1024) {
    return `${(size / 1024).toFixed(1)} KB`;
  }
  return `${(size / 1024 / 1024).toFixed(1)} MB`;
}

function formatTime(ts: number): string {
  if (ts <= 0) {
    return '';
  }
  const date = new Date(ts * 1000);
  const y = date.getFullYear();
  const m = `${date.getMonth() + 1}`.padStart(2, '0');
  const d = `${date.getDate()}`.padStart(2, '0');
  return `${y}-${m}-${d}`;
}

/** 可编辑的文本后缀 */
function isEditableText(name: string): boolean {
  const lower = name.toLowerCase();
  return lower.endsWith('.conf') || lower.endsWith('.lua') || lower.endsWith('.txt') ||
    lower.endsWith('.json') || lower.endsWith('.md') || lower.indexOf('.') < 0;
}

function fileIcon(entry: ConfigFileEntry): Resource {
  if (entry.isDir) {
    return $r('sys.symbol.folder_fill');
  }
  const lower = entry.name.toLowerCase();
  if (lower.endsWith('.lua')) {
    return $r('sys.symbol.puzzle');
  }
  if (lower.endsWith('.conf')) {
    return $r('sys.symbol.gearshape');
  }
  return $r('sys.symbol.doc_plaintext');
}

@ComponentV2
export struct ConfigBrowserPage {
  @Local entries: ConfigFileEntry[] = [];
  @Local currentDir: string = '';
  @Local breadcrumbs: Breadcrumb[] = [{ name: 'mpv', rel: '' }];
  // 编辑弹层
  @Local showEditor: boolean = false;
  @Local editorTitle: string = '';
  @Local editorText: string = '';
  @Local editorRelPath: string = '';
  // 新建弹层
  @Local showCreate: boolean = false;
  @Local createName: string = '';
  @Local createAsDir: boolean = false;
  // 重命名弹层
  @Local showRename: boolean = false;
  @Local renameName: string = '';
  private renameTarget: ConfigFileEntry | null = null;

  private get context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.entries = MpvConfigManager.listConfigDir(this.context, this.currentDir);
  }

  private enterDir(entry: ConfigFileEntry): void {
    this.currentDir = entry.path;
    this.breadcrumbs.push({ name: entry.name, rel: entry.path });
    this.reload();
  }

  private jumpTo(rel: string): void {
    const idx = this.breadcrumbs.findIndex((b: Breadcrumb) => b.rel === rel);
    if (idx >= 0) {
      this.breadcrumbs = this.breadcrumbs.slice(0, idx + 1);
      this.currentDir = rel;
      this.reload();
    }
  }

  private openFile(entry: ConfigFileEntry): void {
    if (!isEditableText(entry.name)) {
      this.getUIContext().getPromptAction()
        .showToast({ message: '二进制文件暂不支持编辑，可导出后在电脑上处理' });
      return;
    }
    if (entry.path.split('/')[0] === 'scripts') {
      // 插件已内化：scripts/ 由应用统一管理，配置浏览器只读
      this.getUIContext().getPromptAction()
        .showToast({ message: '插件已内化，脚本文件由应用管理，不可编辑' });
      return;
    }
    this.editorTitle = entry.name;
    this.editorRelPath = entry.path;
    this.editorText = MpvConfigManager.readConfigFile(this.context, entry.path);
    this.showEditor = true;
  }

  private saveEditor(): void {
    try {
      MpvConfigManager.writeConfigFile(this.context, this.editorRelPath, this.editorText);
      this.showEditor = false;
      this.reload();
      this.getUIContext().getPromptAction().showToast({ message: '已保存，下次播放生效' });
    } catch (err) {
      this.getUIContext().getPromptAction()
        .showToast({ message: `保存失败: ${(err as Error).message}` });
    }
  }

  private doCreate(): void {
    const name = this.createName.trim();
    if (name.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请输入名称' });
      return;
    }
    try {
      const finalPath = MpvConfigManager.createConfigEntry(
        this.context, this.currentDir, name, this.createAsDir);
      this.showCreate = false;
      this.createName = '';
      this.reload();
      this.getUIContext().getPromptAction()
        .showToast({ message: `已创建 ${finalPath.substring(finalPath.lastIndexOf('/') + 1)}` });
    } catch (err) {
      this.getUIContext().getPromptAction()
        .showToast({ message: `创建失败: ${(err as Error).message}` });
    }
  }

  private openRename(entry: ConfigFileEntry): void {
    this.renameTarget = entry;
    this.renameName = entry.name;
    this.showRename = true;
  }

  private doRename(): void {
    const name = this.renameName.trim();
    if (name.length === 0 || this.renameTarget === null) {
      return;
    }
    try {
      MpvConfigManager.renameConfigEntry(this.context, this.renameTarget.path, name);
      this.showRename = false;
      this.reload();
    } catch (err) {
      this.getUIContext().getPromptAction()
        .showToast({ message: `重命名失败: ${(err as Error).message}` });
    }
  }

  private doDelete(entry: ConfigFileEntry): void {
    try {
      MpvConfigManager.deleteConfigEntry(this.context, entry.path);
      this.reload();
      this.getUIContext().getPromptAction().showToast({ message: `已删除 ${entry.name}` });
    } catch (err) {
      this.getUIContext().getPromptAction()
        .showToast({ message: `删除失败: ${(err as Error).message}` });
    }
  }

  private onEntryTap(entry: ConfigFileEntry): void {
    if (entry.isDir) {
      this.enterDir(entry);
    } else {
      this.openFile(entry);
    }
  }

  @Builder
  fileItemEnd(entry: ConfigFileEntry) {
    Row({ space: 8 }) {
      Button('重命名')
        .fontSize(13)
        .fontColor(Color.White)
        .height(40)
        .padding({ left: 14, right: 14 })
        .borderRadius(20)
        .backgroundColor($r('app.color.brand'))
        .onClick(() => this.openRename(entry))
      Button('删除')
        .fontSize(13)
        .fontColor(Color.White)
        .height(40)
        .padding({ left: 14, right: 14 })
        .borderRadius(20)
        .backgroundColor($r('app.color.warning'))
        .onClick(() => this.doDelete(entry))
    }
    .margin({ left: 8 })
  }

  @Builder
  fileItem(entry: ConfigFileEntry, idx: number) {
    ListItem() {
      Column() {
        Row({ space: 14 }) {
          SymbolGlyph(fileIcon(entry))
            .fontSize(24)
            .fontColor([entry.isDir ? $r('app.color.brand') : $r('app.color.text_secondary')])
          Column({ space: 3 }) {
            Text(entry.name)
              .fontSize(16)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (!entry.isDir) {
              Text(`${formatSize(entry.size)}${entry.mtime > 0 ? ` · ${formatTime(entry.mtime)}` : ''}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            } else {
              Text('文件夹')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(14)
            .fontColor([$r('app.color.text_tertiary')])
        }
        .width('100%')
        .height(64)
        .padding({ left: 16, right: 16 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => this.onEntryTap(entry))
        if (idx < this.entries.length - 1) {
          Divider()
            .color($r('app.color.list_divider'))
            .margin({ left: 54 })
        }
      }
    }
    .swipeAction({
      end: {
        builder: () => {
          this.fileItemEnd(entry)
        },
        onAction: () => {
        },
        actionAreaDistance: 56,
      },
    })
  }

  @Builder
  breadcrumbBar() {
    Scroll() {
      Row({ space: 6 }) {
        ForEach(this.breadcrumbs, (crumb: Breadcrumb, idx: number) => {
          Text(crumb.name)
            .fontSize(15)
            .fontWeight(idx === this.breadcrumbs.length - 1 ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(idx === this.breadcrumbs.length - 1 ?
              $r('app.color.text_primary') : $r('app.color.brand'))
            .maxLines(1)
            .onClick(() => this.jumpTo(crumb.rel))
          if (idx < this.breadcrumbs.length - 1) {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(12)
              .fontColor([$r('app.color.text_tertiary')])
          }
        }, (crumb: Breadcrumb, idx: number) => `${idx}-${crumb.rel}`)
      }
      .padding({ left: 16, right: 16 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(40)
  }

  @Builder
  pageMenu() {
    Menu() {
      MenuItem({
        content: '新建文件',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.plus_square'))
          .fontColor([$r('app.color.brand')]),
      })
        .onClick(() => {
          this.createAsDir = false;
          this.showCreate = true;
        })
      MenuItem({
        content: '新建文件夹',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.folder_badge_plus'))
          .fontColor([$r('app.color.brand')]),
      })
        .onClick(() => {
          this.createAsDir = true;
          this.showCreate = true;
        })
    }
  }

  @Builder
  editorSheet() {
    Column({ space: 12 }) {
      Text(this.editorTitle)
        .fontSize(15)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      TextArea({ text: this.editorText, placeholder: '文件内容' })
        .height(380)
        .fontSize(13)
        .fontFamily('monospace')
        .backgroundColor($r('app.color.input_background'))
        .fontColor($r('app.color.text_primary'))
        .borderRadius(12)
        .constraintSize({ minHeight: 200 })
        .onChange((v: string) => {
          this.editorText = v;
        })
      Row({ space: 12 }) {
        Button('取消')
          .height(44)
          .fontSize(16)
          .layoutWeight(1)
          .backgroundColor($r('app.color.input_background'))
          .fontColor($r('app.color.text_secondary'))
          .borderRadius(22)
          .onClick(() => {
            this.showEditor = false;
          })
        Button('保存')
          .height(44)
          .fontSize(16)
          .layoutWeight(1)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.text_on_brand'))
          .borderRadius(22)
          .onClick(() => this.saveEditor())
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8 })
  }

  @Builder
  createSheet() {
    Column({ space: 12 }) {
      Text(this.createAsDir ? '新建文件夹' : '新建文件')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 4 })
      TextInput({ text: this.createName, placeholder: this.createAsDir ? '文件夹名' : '文件名（如 my-script.lua）' })
        .height(48)
        .fontSize(16)
        .backgroundColor($r('app.color.input_background'))
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .borderRadius(12)
        .onChange((v: string) => {
          this.createName = v;
        })
      Button('创建')
        .height(44)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .backgroundColor($r('app.color.brand'))
        .fontColor($r('app.color.text_on_brand'))
        .borderRadius(22)
        .margin({ bottom: 28 })
        .onClick(() => this.doCreate())
    }
    .width('100%')
    .padding({ left: 20, right: 20 })
  }

  @Builder
  renameSheet() {
    Column({ space: 12 }) {
      Text('重命名')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 4 })
      TextInput({ text: this.renameName, placeholder: '新名称' })
        .height(48)
        .fontSize(16)
        .backgroundColor($r('app.color.input_background'))
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .borderRadius(12)
        .onChange((v: string) => {
          this.renameName = v;
        })
      Button('确定')
        .height(44)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .backgroundColor($r('app.color.brand'))
        .fontColor($r('app.color.text_on_brand'))
        .borderRadius(22)
        .margin({ bottom: 28 })
        .onClick(() => this.doRename())
    }
    .width('100%')
    .padding({ left: 20, right: 20 })
  }

  build() {
    NavDestination() {
      Column() {
        // 面包屑
        Column() {
          this.breadcrumbBar()
          Divider()
            .color($r('app.color.list_divider'))
        }
        .width('100%')

        // 文件列表（List 分组卡片）
        if (this.entries.length > 0) {
          List({ space: 0, initialIndex: 0 }) {
            ForEach(this.entries, (entry: ConfigFileEntry, idx: number) => {
              this.fileItem(entry, idx)
            }, (entry: ConfigFileEntry) => `${entry.path}-${entry.size}-${entry.mtime}`)
          }
          .width('100%')
          .layoutWeight(1)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .margin({ left: 16, right: 16, top: 8 })
          .clip(true)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        } else {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(44)
              .fontColor([$r('app.color.text_tertiary')])
            Text('空目录。可通过右上角菜单新建文件或文件夹。')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
    }
    .title('配置管理')
    .menus(this.pageMenu())
    .backgroundColor($r('app.color.page_background'))
    .onBackPressed(() => {
      if (this.breadcrumbs.length > 1) {
        this.breadcrumbs.pop();
        this.currentDir = this.breadcrumbs[this.breadcrumbs.length - 1].rel;
        this.reload();
        return true;
      }
      return false;
    })
    .bindSheet($$this.showEditor, this.editorSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '编辑文件' },
    })
    .bindSheet($$this.showCreate, this.createSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '新建' },
    })
    .bindSheet($$this.showRename, this.renameSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '重命名' },
    })
  }
}
