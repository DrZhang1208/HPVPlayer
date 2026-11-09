/**
 * HPVPlayer - 资源库 Tab：本地文件夹（持久授权）+ WebDAV 服务器管理。
 * 由 Index（Tabs 容器）内嵌。
 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileShare } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MediaSource, sourceItemCount } from '../models/Library';
import { LibraryStore } from '../services/LibraryStore';
import { Scanner, ScanProgress } from '../services/Scanner';
import { Scraper } from '../services/Scraper';
import { appNav, NavRoutes, WebDavBrowseParam } from '../services/AppNav';

const DOMAIN = 0x0000;

function formatScanTime(ts: number): string {
  if (ts <= 0) {
    return '未扫描';
  }
  const diff = Date.now() - ts;
  const minute = 60 * 1000;
  if (diff < minute) {
    return '刚刚扫描';
  }
  if (diff < 60 * minute) {
    return `${Math.floor(diff / minute)} 分钟前扫描`;
  }
  if (diff < 24 * 60 * minute) {
    return `${Math.floor(diff / 60 / minute)} 小时前扫描`;
  }
  return `${Math.floor(diff / 24 / 60 / minute)} 天前扫描`;
}

@ComponentV2
export struct SourcesTab {
  @Local scanningId: string = '';
  @Local scanProgress: string = '';
  @Local refreshing: boolean = false;
  @Local showEdit: boolean = false;
  @Local editId: string = '';
  @Local editName: string = '';
  @Local editUrl: string = '';
  @Local editUser: string = '';
  @Local editPass: string = '';
  @Local editInsecure: boolean = false;

  private get store(): LibraryStore {
    return LibraryStore.get();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // ---------- 本地文件夹 ----------

  private async addLocalFolder(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const docPicker = new picker.DocumentViewPicker(context);
      const result: string[] = await docPicker.select({
        selectMode: picker.DocumentSelectMode.FOLDER,
        maxSelectNumber: 1,
      });
      if (result.length === 0) {
        return;
      }
      const folderUri = result[0];
      // 持久授权（跨重启可读）
      try {
        await fileShare.persistPermission([{
          uri: folderUri,
          operationMode: fileShare.OperationMode.READ_MODE,
        }]);
      } catch (err) {
        hilog.warn(DOMAIN, 'HPVPlayer', 'persistPermission failed: %{public}s',
          JSON.stringify(err));
      }
      const name = new fileUri.FileUri(folderUri).name || `文件夹 ${this.store.sources.length + 1}`;
      const id = `local-${Date.now()}`;
      this.store.addSource({
        id: id,
        type: 'local',
        name: name,
        folderUri: folderUri,
        lastScanTs: 0,
      });
      this.toast(`已添加: ${name}，开始扫描…`);
      const added = this.store.getSource(id);
      if (added !== null) {
        this.scanSource(added);
      }
    } catch (err) {
      hilog.error(DOMAIN, 'HPVPlayer', 'pick folder failed: %{public}s', JSON.stringify(err));
      this.toast('选择文件夹失败');
    }
  }

  private async removeSource(source: MediaSource): Promise<void> {
    if (source.type === 'local' && source.folderUri !== undefined) {
      try {
        await fileShare.revokePermission([{
          uri: source.folderUri,
          operationMode: fileShare.OperationMode.READ_MODE,
        }]);
      } catch (err) {
        // 忽略撤销失败（权限可能已失效）
      }
    }
    this.store.removeSource(source.id);
    this.toast('已删除来源');
  }

  // ---------- 扫描 ----------

  private async scanSource(source: MediaSource): Promise<void> {
    if (source === undefined || source === null) {
      return;
    }
    if (this.scanningId !== '') {
      return;
    }
    this.scanningId = source.id;
    this.scanProgress = '扫描中…';
    const result = await Scanner.scan(source, (p: ScanProgress) => {
      this.scanProgress = `已发现 ${p.found} 项`;
    });
    if (result.error !== '') {
      this.toast(`扫描失败: ${result.error}`);
    } else {
      this.store.applyScanResult(source.id, result.items);
      this.store.updateSource({
        id: source.id,
        type: source.type,
        name: source.name,
        folderUri: source.folderUri,
        url: source.url,
        user: source.user,
        password: source.password,
        allowInsecure: source.allowInsecure,
        scanDepth: source.scanDepth,
        lastScanTs: Date.now(),
      });
      this.toast(`扫描完成: ${result.items.length} 项`);
      // 扫描后尝试刮削（无 Key 静默跳过）
      try {
        await Scraper.scrapeAll();
      } catch (err) {
        // 无 Key / 网络问题静默
      }
    }
    this.scanningId = '';
  }

  private async scanAllSources(): Promise<void> {
    for (const source of this.store.sources) {
      await this.scanSource(source);
    }
  }

  // ---------- WebDAV 表单 ----------

  private openEditor(source: MediaSource | null): void {
    if (source !== null) {
      this.editId = source.id;
      this.editName = source.name;
      this.editUrl = source.url ?? '';
      this.editUser = source.user ?? '';
      this.editPass = source.password ?? '';
      this.editInsecure = source.allowInsecure ?? false;
    } else {
      this.editId = '';
      this.editName = '';
      this.editUrl = '';
      this.editUser = '';
      this.editPass = '';
      this.editInsecure = false;
    }
    this.showEdit = true;
  }

  private async saveServer(): Promise<void> {
    let url = this.editUrl.trim();
    if (this.editName.trim().length === 0 || url.length === 0) {
      this.toast('请填写名称和地址');
      return;
    }
    if (!/^https?:\/\//.test(url)) {
      url = `http://${url}`;
    }
    if (url.endsWith('/') && url.length > 'http://'.length + 1) {
      url = url.substring(0, url.length - 1);
    }
    if (this.editId.length === 0) {
      this.store.addSource({
        id: `dav-${Date.now()}`,
        type: 'webdav',
        name: this.editName.trim(),
        url: url,
        user: this.editUser.trim(),
        password: this.editPass,
        allowInsecure: this.editInsecure,
        scanDepth: 3,
        lastScanTs: 0,
      });
    } else {
      const old = this.store.getSource(this.editId);
      this.store.updateSource({
        id: this.editId,
        type: 'webdav',
        name: this.editName.trim(),
        url: url,
        user: this.editUser.trim(),
        password: this.editPass,
        allowInsecure: this.editInsecure,
        scanDepth: old?.scanDepth ?? 3,
        lastScanTs: old?.lastScanTs ?? 0,
      });
    }
    this.showEdit = false;
  }

  // ---------- 构建 ----------

  @Builder
  sourceCard(source: MediaSource) {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        SymbolGlyph(source.type === 'local' ?
          $r('sys.symbol.folder_fill') : $r('sys.symbol.externaldrive_fill'))
          .fontSize(22)
          .fontColor([$r('app.color.brand')])
          .width(40)
          .height(40)
          .backgroundColor($r('app.color.brand_light'))
          .borderRadius(12)
        Column({ space: 2 }) {
          Text(source.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
          Text(source.type === 'local' ?
            `${sourceItemCount(this.store.items, source.id)} 个媒体 · ${formatScanTime(source.lastScanTs)}` :
            `${sourceItemCount(this.store.items, source.id)} 个媒体 · ${source.url ?? ''}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Row({ space: 8 }) {
        if (this.scanningId === source.id) {
          Row({ space: 6 }) {
            LoadingProgress().width(16).height(16).color($r('app.color.brand'))
            Text(this.scanProgress)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
        } else {
          Text('扫描')
            .fontSize(14)
            .fontColor($r('app.color.brand'))
            .height(32)
            .padding({ left: 16, right: 16 })
            .textAlign(TextAlign.Center)
            .backgroundColor($r('app.color.brand_light'))
            .borderRadius(16)
            .onClick(() => this.scanSource(source))
          if (source.type === 'webdav') {
            Text('浏览')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .height(32)
              .padding({ left: 16, right: 16 })
              .textAlign(TextAlign.Center)
              .backgroundColor($r('app.color.input_background'))
              .borderRadius(16)
              .onClick(() => {
                const param: WebDavBrowseParam = { sourceId: source.id };
                appNav.pushPath({ name: NavRoutes.WEBDAV, param: param });
              })
            Text('编辑')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .height(32)
              .padding({ left: 16, right: 16 })
              .textAlign(TextAlign.Center)
              .backgroundColor($r('app.color.input_background'))
              .borderRadius(16)
              .onClick(() => this.openEditor(source))
          }
          Blank()
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(20)
            .fontColor([$r('app.color.warning')])
            .width(36).height(32)
            .onClick(() => this.removeSource(source))
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_background'))
    .margin({ bottom: 12 })
  }

  @Builder
  editSheetView() {
    Column({ space: 12 }) {
      Text(this.editId.length > 0 ? '编辑 WebDAV' : '添加 WebDAV')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 4 })

      TextInput({ text: this.editName, placeholder: '名称（如：我的 NAS）' })
        .height(48)
        .fontSize(16)
        .backgroundColor($r('app.color.input_background'))
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .borderRadius(12)
        .onChange((v: string) => {
          this.editName = v;
        })
      TextInput({ text: this.editUrl, placeholder: '地址（如 192.168.1.10:5005/dav）' })
        .height(48)
        .fontSize(16)
        .backgroundColor($r('app.color.input_background'))
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .borderRadius(12)
        .onChange((v: string) => {
          this.editUrl = v;
        })
      Row({ space: 10 }) {
        TextInput({ text: this.editUser, placeholder: '用户名（可空）' })
          .height(48)
          .fontSize(16)
          .backgroundColor($r('app.color.input_background'))
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .borderRadius(12)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.editUser = v;
          })
        TextInput({ text: this.editPass, placeholder: '密码（可空）' })
          .height(48)
          .fontSize(16)
          .type(InputType.Password)
          .backgroundColor($r('app.color.input_background'))
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .borderRadius(12)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.editPass = v;
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Toggle({ type: ToggleType.Switch, isOn: this.editInsecure })
          .onChange((on: boolean) => {
            this.editInsecure = on;
          })
        Text('允许自签名证书（HTTPS）')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')

      Row({ space: 12 }) {
        Button('取消')
          .height(44)
          .fontSize(16)
          .layoutWeight(1)
          .backgroundColor($r('app.color.input_background'))
          .fontColor($r('app.color.text_secondary'))
          .borderRadius(22)
          .onClick(() => {
            this.showEdit = false;
          })
        Button('保存')
          .height(44)
          .fontSize(16)
          .layoutWeight(1)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.text_on_brand'))
          .borderRadius(22)
          .onClick(() => this.saveServer())
      }
      .width('100%')
      .margin({ top: 4, bottom: 28 })
    }
    .width('100%')
    .padding({ left: 20, right: 20 })
  }

  build() {
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column() {
          // 添加本地文件夹（大按钮）
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.folder_badge_plus'))
              .fontSize(24)
              .fontColor([$r('app.color.brand')])
            Column({ space: 2 }) {
              Text('添加本地文件夹')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('选择视频所在目录，授权后自动扫描（支持子目录）')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(14)
              .fontColor([$r('app.color.text_tertiary')])
          }
          .width('100%')
          .padding(16)
          .borderRadius(16)
          .border({ width: 1.5, color: $r('app.color.brand_light') })
          .margin({ bottom: 12 })
          .onClick(() => this.addLocalFolder())

          // WebDAV 添加入口
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.externaldrive_fill'))
              .fontSize(24)
              .fontColor([$r('app.color.brand')])
            Column({ space: 2 }) {
              Text('添加 WebDAV 服务器')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('NAS / 坚果云 / Alist，扫描入库或直接浏览')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(16)
              .fontColor([$r('app.color.text_tertiary')])
          }
          .width('100%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .margin({ bottom: 12 })
          .onClick(() => this.openEditor(null))

          // 来源列表
          ForEach(this.store.sources, (source: MediaSource) => {
            this.sourceCard(source)
          }, (source: MediaSource) => `${source.id}-${source.lastScanTs}`)

          if (this.store.sources.length > 0) {
            Button('全部重新扫描')
              .height(40)
              .fontSize(14)
              .fontColor($r('app.color.brand'))
              .width('100%')
              .backgroundColor($r('app.color.brand_light'))
              .borderRadius(20)
              .margin({ top: 4 })
              .onClick(() => this.scanAllSources())
          } else {
            Text('还没有来源。添加本地文件夹或 WebDAV 服务器后，\n视频会自动扫描入库并匹配海报。')
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.Center)
              .margin({ top: 16 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      }
      .scrollBar(BarState.Off)
    }
    .onRefreshing(() => {
      this.scanAllSources().then(() => {
        this.refreshing = false;
      });
    })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .bindSheet($$this.showEdit, this.editSheetView(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
    })
  }
}
