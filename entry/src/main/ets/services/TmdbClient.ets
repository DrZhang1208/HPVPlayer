/**
 * HPVPlayer - TMDB 刮削客户端（v3 API，用户自备 Key，可配镜像域名）。
 */
import rcp from '@hms.collaboration.rcp';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ScrapeConfig } from './SettingsStore';

const DOMAIN = 0x0000;
const DEFAULT_BASE = 'api.themoviedb.org';
const IMAGE_HOST = 'https://image.tmdb.org/t/p';

export interface TmdbHit {
  id: number;
  title: string;
  year: number;
  overview: string;
  rating: number;
  posterPath: string;
  backdropPath: string;
  releaseDate: string;
}

interface TmdbRawItem {
  id?: number;
  title?: string;
  name?: string;
  original_title?: string;
  original_name?: string;
  overview?: string;
  vote_average?: number;
  poster_path?: string;
  backdrop_path?: string;
  release_date?: string;
  first_air_date?: string;
}

interface TmdbRawCastEntry {
  name?: string;
  character?: string;
}

interface TmdbRawGenre {
  name?: string;
}

interface TmdbRawEpisode {
  episode_number?: number;
  name?: string;
}

interface TmdbSeasonResponse {
  episodes?: TmdbRawEpisode[];
}

interface TmdbCredits {
  cast?: TmdbRawCastEntry[];
}

interface TmdbDetailsResponse {
  title?: string;
  name?: string;
  original_title?: string;
  original_name?: string;
  runtime?: number;
  episode_run_time?: number[];
  genres?: TmdbRawGenre[];
  credits?: TmdbCredits;
}

interface TmdbSearchResponse {
  results?: TmdbRawItem[];
}

/** TMDB 详情附加信息（append_to_response=credits） */
export interface TmdbDetails {
  /** 详情页规范标题（中文名优先，回落原名） */
  title: string;
  runtime: number;
  genres: string[];
  /** "名字 饰 角色" 列表 */
  cast: string[];
}

export class TmdbClient {
  private static session: rcp.Session | null = null;
  private static cacheDir: string = '';

  /** 初始化（设置海报缓存目录 = filesDir/artworks） */
  static init(context: common.UIAbilityContext): void {
    TmdbClient.cacheDir = context.filesDir + '/artworks';
  }

  private static getSession(): rcp.Session {
    if (TmdbClient.session === null) {
      TmdbClient.session = rcp.createSession({
        requestConfiguration: {
          proxy: 'system', // 国内网络可走系统代理
          transfer: { timeout: { connectMs: 8000, transferMs: 15000 } },
        },
      });
    }
    return TmdbClient.session;
  }

  static async searchMovie(config: ScrapeConfig, query: string,
    year?: number): Promise<TmdbHit[]> {
    let path = `/3/search/movie?query=${encodeURIComponent(query)}&language=zh-CN` +
      `&api_key=${config.apiKey}`;
    if (year !== undefined) {
      path += `&year=${year}`;
    }
    const root = await TmdbClient.getJson(config, path) as TmdbSearchResponse;
    return TmdbClient.mapResults(root, 'movie');
  }

  static async searchTv(config: ScrapeConfig, query: string,
    year?: number): Promise<TmdbHit[]> {
    let path = `/3/search/tv?query=${encodeURIComponent(query)}&language=zh-CN` +
      `&api_key=${config.apiKey}`;
    if (year !== undefined) {
      path += `&first_air_date_year=${year}`;
    }
    const root = await TmdbClient.getJson(config, path) as TmdbSearchResponse;
    return TmdbClient.mapResults(root, 'tv');
  }

  /** 下载海报/背景图到沙箱缓存，返回文件绝对路径；失败返回空串 */
  static async downloadImage(tmdbImagePath: string,
    width: 'w500' | 'w780'): Promise<string> {
    if (tmdbImagePath.length === 0 || TmdbClient.cacheDir === '') {
      return '';
    }
    try {
      const fileName = `${width}${tmdbImagePath.replace(/[^a-zA-Z0-9.]/g, '_')}`;
      const target = `${TmdbClient.cacheDir}/${fileName}`;
      if (fs.accessSync(target)) {
        return target; // 已缓存
      }
      const url = `${IMAGE_HOST}/${width}${tmdbImagePath}`;
      const response = await TmdbClient.getSession().fetch(new rcp.Request(url, 'GET'));
      if (response.statusCode !== 200 || response.body === undefined) {
        return '';
      }
      if (!fs.accessSync(TmdbClient.cacheDir)) {
        fs.mkdirSync(TmdbClient.cacheDir, true);
      }
      const file = fs.openSync(target,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, response.body);
      } finally {
        fs.closeSync(file);
      }
      return target;
    } catch (err) {
      hilog.warn(DOMAIN, 'HPVPlayer', 'download image failed: %{public}s', JSON.stringify(err));
      return '';
    }
  }

  /** 获取详情+演员表（电影 /3/movie/{id}?append_to_response=credits，剧集同理） */
  static async getDetails(config: ScrapeConfig, tmdbId: number,
    type: 'movie' | 'tv'): Promise<TmdbDetails> {
    const path = `/3/${type}/${tmdbId}?language=zh-CN&append_to_response=credits&api_key=${config.apiKey}`;
    const root = await TmdbClient.getJson(config, path) as TmdbDetailsResponse;
    const localName = (type === 'movie' ? root.title : root.name) ?? '';
    const originalName = (type === 'movie' ? root.original_title : root.original_name) ?? '';
    const genres: string[] = [];
    for (const g of root.genres ?? []) {
      if ((g.name ?? '').length > 0) {
        genres.push(g.name as string);
      }
    }
    const cast: string[] = [];
    for (const c of (root.credits?.cast ?? []).slice(0, 12)) {
      const name = c.name ?? '';
      const character = c.character ?? '';
      if (name.length === 0) {
        continue;
      }
      cast.push(character.length > 0 ? `${name} 饰 ${character}` : name);
    }
    let runtime = root.runtime ?? 0;
    if (type === 'tv' && runtime === 0 && (root.episode_run_time ?? []).length > 0) {
      runtime = root.episode_run_time![0];
    }
    return {
      title: localName.length > 0 ? localName : originalName,
      runtime: runtime,
      genres: genres,
      cast: cast,
    };
  }

  /** 获取剧集某一季的分集标题（集号 → 集名） */
  static async getSeasonEpisodes(config: ScrapeConfig, tmdbId: number,
    season: number): Promise<Map<number, string>> {
    const seasonNo = season > 0 ? season : 1;
    const path = `/3/tv/${tmdbId}/season/${seasonNo}?language=zh-CN&api_key=${config.apiKey}`;
    const root = await TmdbClient.getJson(config, path) as TmdbSeasonResponse;
    const map = new Map<number, string>();
    for (const ep of root.episodes ?? []) {
      const no = ep.episode_number ?? 0;
      const name = ep.name ?? '';
      if (no > 0 && name.length > 0) {
        map.set(no, name);
      }
    }
    return map;
  }

  private static async getJson(config: ScrapeConfig,
    path: string): Promise<TmdbSearchResponse | TmdbDetailsResponse | TmdbSeasonResponse> {
    const base = (config.baseUrl.length > 0 ? config.baseUrl : DEFAULT_BASE)
      .replace(/^https?:\/\//, '').replace(/\/+$/, '');
    const url = `https://${base}${path}`;
    const response = await TmdbClient.getSession().fetch(new rcp.Request(url, 'GET'));
    if (response.statusCode === 401) {
      throw new Error('TMDB API Key 无效');
    }
    if (response.statusCode !== 200) {
      throw new Error(`TMDB 请求失败: HTTP ${response.statusCode}`);
    }
    return JSON.parse(response.toString() ?? '{}');
  }

  private static mapResults(root: TmdbSearchResponse, type: 'movie' | 'tv'): TmdbHit[] {
    const hits: TmdbHit[] = [];
    for (const r of root.results ?? []) {
      const date = (type === 'movie' ? r.release_date : r.first_air_date) ?? '';
      if ((r.id ?? 0) === 0) {
        continue;
      }
      // 优先中文名，无中文名回落原名（zh-CN 请求下部分条目 title 为空）
      const localName = (type === 'movie' ? r.title : r.name) ?? '';
      const originalName = (type === 'movie' ? r.original_title : r.original_name) ?? '';
      hits.push({
        id: r.id as number,
        title: localName.length > 0 ? localName : originalName,
        year: date.length >= 4 ? parseInt(date.substring(0, 4)) : 0,
        overview: r.overview ?? '',
        rating: r.vote_average ?? 0,
        posterPath: r.poster_path ?? '',
        backdropPath: r.backdrop_path ?? '',
        releaseDate: date,
      });
    }
    return hits;
  }
}
