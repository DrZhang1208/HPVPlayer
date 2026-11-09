/**
 * HPVPlayer - 应用设置持久化（preferences）。
 *
 * 存储: WebDAV 服务器列表 / 最近播放 / 播放偏好。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export interface DavServer {
  id: string;
  name: string;
  url: string;
  user: string;
  password: string;
  allowInsecure: boolean;
}

export interface RecentItem {
  title: string;
  uri: string;
  headers?: Record<string, string>;
  kind: 'url' | 'local' | 'webdav';
  ts: number;
}

export interface PlayerPreferences {
  alang: string;
  slang: string;
  hwdec: boolean;
}

export interface ScrapeConfig {
  enabled: boolean;
  apiKey: string;
  /** TMDB API 域名，默认 api.themoviedb.org，可填镜像 */
  baseUrl: string;
}

const KEY_SERVERS = 'webdav_servers';
const KEY_RECENTS = 'recents';
const KEY_PREFS = 'player_prefs';
const KEY_SCRAPE = 'scrape_config';
const MAX_RECENTS = 20;

export class SettingsStore {
  private static store: preferences.Preferences | null = null;

  static async init(context: common.UIAbilityContext): Promise<void> {
    if (SettingsStore.store === null) {
      SettingsStore.store = await preferences.getPreferences(context, 'hpvplayer_settings');
    }
  }

  // ---------- WebDAV 服务器 ----------

  static async getServers(): Promise<DavServer[]> {
    const raw = (await SettingsStore.store?.get(KEY_SERVERS, '[]')) as string;
    try {
      return JSON.parse(raw) as DavServer[];
    } catch (err) {
      hilog.warn(0, 'HPVPlayer', 'parse servers failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  static async setServers(servers: DavServer[]): Promise<void> {
    await SettingsStore.store?.put(KEY_SERVERS, JSON.stringify(servers));
    await SettingsStore.store?.flush();
  }

  // ---------- 最近播放 ----------

  static async getRecents(): Promise<RecentItem[]> {
    const raw = (await SettingsStore.store?.get(KEY_RECENTS, '[]')) as string;
    try {
      return JSON.parse(raw) as RecentItem[];
    } catch (err) {
      return [];
    }
  }

  static async addRecent(item: RecentItem): Promise<void> {
    let list = await SettingsStore.getRecents();
    // 同一 uri 去重并置顶
    list = list.filter((r: RecentItem) => r.uri !== item.uri);
    list.unshift(item);
    if (list.length > MAX_RECENTS) {
      list = list.slice(0, MAX_RECENTS);
    }
    await SettingsStore.store?.put(KEY_RECENTS, JSON.stringify(list));
    await SettingsStore.store?.flush();
  }

  static async removeRecent(uri: string): Promise<void> {
    let list = await SettingsStore.getRecents();
    list = list.filter((r: RecentItem) => r.uri !== uri);
    await SettingsStore.store?.put(KEY_RECENTS, JSON.stringify(list));
    await SettingsStore.store?.flush();
  }

  static async clearRecents(): Promise<void> {
    await SettingsStore.store?.put(KEY_RECENTS, '[]');
    await SettingsStore.store?.flush();
  }

  // ---------- 播放偏好 ----------

  static async getPreferencesValue(): Promise<PlayerPreferences> {
    const raw = (await SettingsStore.store?.get(KEY_PREFS, '')) as string;
    const fallback: PlayerPreferences = { alang: 'chi', slang: 'chi', hwdec: true };
    if (raw === '') {
      return fallback;
    }
    try {
      const parsed = JSON.parse(raw) as PlayerPreferences;
      return {
        alang: parsed.alang ?? 'chi',
        slang: parsed.slang ?? 'chi',
        hwdec: parsed.hwdec ?? true,
      };
    } catch (err) {
      return fallback;
    }
  }

  static async setPreferencesValue(prefs: PlayerPreferences): Promise<void> {
    await SettingsStore.store?.put(KEY_PREFS, JSON.stringify(prefs));
    await SettingsStore.store?.flush();
  }

  // ---------- 刮削配置 ----------

  static async getScrapeConfig(): Promise<ScrapeConfig> {
    const raw = (await SettingsStore.store?.get(KEY_SCRAPE, '')) as string;
    if (raw === '') {
      return { enabled: true, apiKey: '', baseUrl: 'api.themoviedb.org' };
    }
    try {
      const parsed = JSON.parse(raw) as ScrapeConfig;
      return {
        enabled: parsed.enabled ?? true,
        apiKey: parsed.apiKey ?? '',
        baseUrl: parsed.baseUrl !== undefined && parsed.baseUrl.length > 0 ?
          parsed.baseUrl : 'api.themoviedb.org',
      };
    } catch (err) {
      return { enabled: true, apiKey: '', baseUrl: 'api.themoviedb.org' };
    }
  }

  static async setScrapeConfig(config: ScrapeConfig): Promise<void> {
    await SettingsStore.store?.put(KEY_SCRAPE, JSON.stringify(config));
    await SettingsStore.store?.flush();
  }
}
