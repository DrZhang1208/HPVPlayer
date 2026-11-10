/**
 * HPVPlayer - 媒体库存储：来源 + 条目，filesDir/library.json 持久化。
 */
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  DetailParam, ItemKind, LibraryGroup, MediaSource, VideoItem
} from '../models/Library';
import { PlayItem } from '../models/PlayItem';
import { DavServer, SettingsStore } from './SettingsStore';
import { WebDavClient } from './WebDavClient';
import { PlayLauncher } from './PlayLauncher';

const DOMAIN = 0x0000;
const LIB_FILE = 'library.json';

interface LibraryData {
  version: number;
  sources: MediaSource[];
  items: VideoItem[];
}

@ObservedV2
export class LibraryStore {
  private static instance: LibraryStore | null = null;
  @Trace sources: MediaSource[] = [];
  @Trace items: VideoItem[] = [];
  @Trace ready: boolean = false;

  private context: common.UIAbilityContext | null = null;

  static get(): LibraryStore {
    if (LibraryStore.instance === null) {
      LibraryStore.instance = new LibraryStore();
    }
    return LibraryStore.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.context !== null) {
      return;
    }
    this.context = context;
    await this.load();
    await this.migrateLegacyServers();
    this.ready = true;
  }

  private libPath(): string {
    return `${this.context!.filesDir}/${LIB_FILE}`;
  }

  private async load(): Promise<void> {
    try {
      const path = this.libPath();
      if (!fs.accessSync(path)) {
        return;
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(path);
        const buf = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buf);
        const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
        const data = JSON.parse(text) as LibraryData;
        this.sources = data.sources ?? [];
        this.items = data.items ?? [];
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'HPVPlayer', 'library load failed: %{public}s', JSON.stringify(err));
    }
  }

  save(): void {
    try {
      const data: LibraryData = { version: 1, sources: this.sources, items: this.items };
      const text = JSON.stringify(data);
      const file = fs.openSync(this.libPath(),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      hilog.error(DOMAIN, 'HPVPlayer', 'library save failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 把旧版 SettingsStore 的 WebDAV 服务器一次性迁移为来源 */
  private async migrateLegacyServers(): Promise<void> {
    const servers = await SettingsStore.getServers();
    if (servers.length === 0) {
      return;
    }
    const existing = this.sources.filter((s: MediaSource) => s.type === 'webdav')
      .map((s: MediaSource) => s.url);
    let changed = false;
    for (const server of servers) {
      if (existing.includes(server.url)) {
        continue;
      }
      this.sources.push(LibraryStore.webdavSourceFrom(server));
      changed = true;
    }
    if (changed) {
      this.save();
    }
    await SettingsStore.setServers([]);
  }

  static webdavSourceFrom(server: DavServer): MediaSource {
    return {
      id: server.id,
      type: 'webdav',
      name: server.name,
      url: server.url,
      user: server.user,
      password: server.password,
      allowInsecure: server.allowInsecure,
      scanDepth: 3,
      lastScanTs: 0,
    };
  }

  static sourceToDavServer(source: MediaSource): DavServer {
    return {
      id: source.id,
      name: source.name,
      url: source.url ?? '',
      user: source.user ?? '',
      password: source.password ?? '',
      allowInsecure: source.allowInsecure ?? false,
    };
  }

  // ---------- 来源管理 ----------

  addSource(source: MediaSource): void {
    this.sources = this.sources.concat([source]);
    this.save();
  }

  updateSource(source: MediaSource): void {
    this.sources = this.sources.map((s: MediaSource) => s.id === source.id ? source : s);
    this.save();
  }

  removeSource(sourceId: string): void {
    this.sources = this.sources.filter((s: MediaSource) => s.id !== sourceId);
    this.items = this.items.filter((i: VideoItem) => i.sourceId !== sourceId);
    this.save();
  }

  getSource(sourceId: string): MediaSource | null {
    for (const s of this.sources) {
      if (s.id === sourceId) {
        return s;
      }
    }
    return null;
  }

  // ---------- 条目 ----------

  /**
   * 合并一次扫描结果：按 uri 去重，保留已有刮削元数据；
   * 移除该来源下已消失的条目。
   */
  applyScanResult(sourceId: string, scanned: VideoItem[]): void {
    const oldByUri = new Map<string, VideoItem>();
    for (const item of this.items) {
      if (item.sourceId === sourceId) {
        oldByUri.set(item.uri, item);
      }
    }
    const merged: VideoItem[] = [];
    const now = Date.now();
    for (const item of scanned) {
      const old = oldByUri.get(item.uri);
      if (old !== undefined) {
        oldByUri.delete(item.uri);
        merged.push(old);
      } else {
        item.addedTs = now;
        merged.push(item);
      }
    }
    const others = this.items.filter((i: VideoItem) => i.sourceId !== sourceId);
    this.items = others.concat(merged);
    this.save();
  }

  updateItem(updated: VideoItem): void {
    this.items = this.items.map((i: VideoItem) => i.id === updated.id ? updated : i);
    this.save();
  }

  // ---------- 查询 ----------

  /** 海报墙分组：电影按标题、剧集按标题+季、未识别按原始文件 */
  getGroups(kind: ItemKind | 'all' | 'recent'): LibraryGroup[] {
    const list = this.buildGroups(kind === 'recent' ? 'all' : kind);
    if (kind === 'recent') {
      list.sort((a: LibraryGroup, b: LibraryGroup) => b.addedTs - a.addedTs);
      return list.slice(0, 24);
    }
    list.sort((a: LibraryGroup, b: LibraryGroup) =>
      a.title.localeCompare(b.title, 'zh-Hans-CN'));
    return list;
  }

  private buildGroups(kind: ItemKind | 'all'): LibraryGroup[] {
    const groups = new Map<string, LibraryGroup>();
    for (const item of this.items) {
      if (kind !== 'all' && item.kind !== kind) {
        continue;
      }
      const key = LibraryStore.groupKey(item);
      let group = groups.get(key);
      if (group === undefined) {
        group = {
          title: item.title,
          kind: item.kind,
          season: item.season ?? -1,
          year: item.year ?? 0,
          posterFile: '',
          items: [],
          addedTs: 0,
          overview: '',
          rating: 0,
          cast: [],
          runtime: 0,
          genres: [],
        };
        groups.set(key, group);
      }
      group.items.push(item);
      if (item.year !== undefined && item.year > 0) {
        group.year = item.year;
      }
      if (item.posterFile !== undefined && item.posterFile !== '' && group.posterFile === '') {
        group.posterFile = item.posterFile;
      }
      if (group.overview === '' && item.overview !== undefined) {
        group.overview = item.overview;
      }
      if (group.rating === 0 && item.rating !== undefined) {
        group.rating = item.rating;
      }
      if (group.cast.length === 0 && item.cast !== undefined) {
        group.cast = item.cast;
      }
      if (group.runtime === 0 && item.runtime !== undefined) {
        group.runtime = item.runtime;
      }
      if (group.genres.length === 0 && item.genres !== undefined) {
        group.genres = item.genres;
      }
      group.addedTs = Math.max(group.addedTs, item.addedTs);
    }
    const list: LibraryGroup[] = [];
    groups.forEach((group: LibraryGroup) => {
      LibraryStore.sortGroupItems(group.items);
      list.push(group);
    });
    return list;
  }

  static groupKey(item: VideoItem): string {
    if (item.kind === 'episode') {
      return `tv|${item.title}|${item.season ?? -1}`;
    }
    if (item.kind === 'movie') {
      return `movie|${item.title}`;
    }
    return `file|${item.name}`;
  }

  /** 详情页取分组 */
  getGroupItems(param: DetailParam): VideoItem[] {
    const list = this.items.filter((item: VideoItem) => {
      if (param.kind === 'episode') {
        return item.kind === 'episode' && item.title === param.title &&
          (item.season ?? -1) === param.season;
      }
      if (param.kind === 'movie') {
        return item.kind === 'movie' && item.title === param.title;
      }
      return item.name === param.title;
    });
    LibraryStore.sortGroupItems(list);
    return list;
  }

  private static sortGroupItems(list: VideoItem[]): void {
    list.sort((a: VideoItem, b: VideoItem) => {
      if (a.kind === 'episode' && b.kind === 'episode') {
        if (a.episode !== undefined && b.episode !== undefined && a.episode !== b.episode) {
          return a.episode - b.episode;
        }
      }
      return a.name.localeCompare(b.name);
    });
  }

  /** 条目 → 播放请求（WebDAV 带认证头） */
  static toPlayItem(item: VideoItem): PlayItem {
    const store = LibraryStore.get();
    const source = store.getSource(item.sourceId);
    const play: PlayItem = { uri: item.uri, title: item.name };
    if (source !== null && source.type === 'webdav') {
      const server = LibraryStore.sourceToDavServer(source);
      play.headers = WebDavClient.authHeaders(server);
      const extra: Record<string, string> = {};
      WebDavClient.extraOptions(server).forEach((value: string, key: string) => {
        extra[key] = value;
      });
      if (Object.keys(extra).length > 0) {
        play.extraOptions = extra;
      }
    }
    return play;
  }

  /** 播放一个分组（按集顺序连播） */
  playGroup(param: DetailParam, index: number = 0): void {
    const items = this.getGroupItems(param);
    if (items.length === 0) {
      return;
    }
    const playItems: PlayItem[] = [];
    for (const item of items) {
      playItems.push(LibraryStore.toPlayItem(item));
    }
    PlayLauncher.play(playItems, Math.min(index, playItems.length - 1),
      items[0].uri.startsWith('http') ? 'webdav' : 'local');
  }
}
