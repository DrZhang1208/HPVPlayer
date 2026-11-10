/**
 * HPVPlayer - 刮削编排：对未匹配条目按解析结果查询元数据源
 * （动漫优先 Bangumi，其余 TMDB），同标题只搜一次，结果写回媒体库并缓存海报。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DetailParam, ItemKind, VideoItem } from '../models/Library';
import { LibraryStore } from './LibraryStore';
import { ScrapeConfig, SettingsStore } from './SettingsStore';
import { TmdbClient, TmdbDetails, TmdbHit } from './TmdbClient';
import { BangumiClient } from './BangumiClient';
import { NameParser } from './NameParser';

const DOMAIN = 0x0000;
const INTER_QUERY_MS = 300; // TMDB 限流保护

export interface ScrapeProgress {
  done: number;
  total: number;
  current: string;
}

/** 手动搜索候选（TMDB 结果，未落库） */
export interface ScrapeCandidate {
  tmdbId: number;
  title: string;
  year: number;
  overview: string;
  rating: number;
  posterPath: string;
  backdropPath: string;
  releaseDate: string;
}

export class Scraper {
  private static running = false;

  static get isRunning(): boolean {
    return Scraper.running;
  }

  /**
   * 刮削所有未匹配条目（同 title+kind+season 的组只查一次）。
   * 返回成功匹配的条目数；无 Key / 网络错误返回 -1 并记录日志。
   */
  static async scrapeAll(onProgress?: (p: ScrapeProgress) => void): Promise<number> {
    if (Scraper.running) {
      return 0;
    }
    const store = LibraryStore.get();
    const config = await SettingsStore.getScrapeConfig();
    if (!config.enabled) {
      return 0;
    }
    if (config.apiKey.length === 0) {
      throw new Error('未配置 TMDB API Key（设置 → 刮削）');
    }

    // 分组待刮削：key → 首个条目（其 title/year/kind 代表整组）
    const pending = new Map<string, VideoItem>();
    for (const item of store.items) {
      if (item.matched) {
        continue;
      }
      const key = `${item.kind}|${item.title}|${item.kind === 'episode' ? item.season ?? -1 : ''}`;
      if (!pending.has(key)) {
        pending.set(key, item);
      }
    }
    if (pending.size === 0) {
      return 0;
    }

    Scraper.running = true;
    let done = 0;
    let matched = 0;
    try {
      const keys = Array.from(pending.keys());
      for (const key of keys) {
        const head = pending.get(key)!;
        if (onProgress !== undefined) {
          onProgress({ done: done, total: keys.length, current: head.title });
        }
        try {
          const hit = await Scraper.scrapeOne(config, head);
          if (hit !== null) {
            matched++;
            // 写回整组
            const items = store.items.filter((i: VideoItem) =>
              !i.matched &&
              i.kind === head.kind &&
              i.title === head.title &&
              (head.kind !== 'episode' || (i.season ?? -1) === (head.season ?? -1)));
            await Scraper.applyHit(config, head.kind, items, hit.id, hit);
            if (items.length > 0) {
              store.save();
            }
          }
        } catch (err) {
          // 单条失败不中断整体
          hilog.warn(DOMAIN, 'HPVPlayer', 'scrape item failed: %{public}s', JSON.stringify(err));
        }
        done++;
        if (onProgress !== undefined) {
          onProgress({ done: done, total: keys.length, current: head.title });
        }
        await Scraper.sleep(INTER_QUERY_MS);
      }
    } finally {
      Scraper.running = false;
    }
    return matched;
  }

  /**
   * 强制重新刮削全部条目（忽略 matched 标记，用于手动刷新）。
   */
  static async rescrapeAll(onProgress?: (p: ScrapeProgress) => void): Promise<number> {
    const store = LibraryStore.get();
    const config = await SettingsStore.getScrapeConfig();
    if (!config.enabled) {
      throw new Error('自动刮削已关闭（设置 → 刮削）');
    }
    if (config.apiKey.length === 0) {
      throw new Error('未配置 TMDB API Key（设置 → 刮削）');
    }

    // 分组待刮削：key → 首个条目
    const pending = new Map<string, VideoItem>();
    for (const item of store.items) {
      const key = `${item.kind}|${item.title}|${item.kind === 'episode' ? item.season ?? -1 : ''}`;
      if (!pending.has(key)) {
        pending.set(key, item);
      }
    }
    if (pending.size === 0) {
      return 0;
    }

    Scraper.running = true;
    let done = 0;
    let matched = 0;
    try {
      const keys = Array.from(pending.keys());
      for (const key of keys) {
        const head = pending.get(key)!;
        if (onProgress !== undefined) {
          onProgress({ done: done, total: keys.length, current: head.title });
        }
        try {
          const hit = await Scraper.scrapeOne(config, head);
          if (hit !== null) {
            matched++;
            // 写回整组
            const items = store.items.filter((i: VideoItem) =>
              i.kind === head.kind &&
              i.title === head.title &&
              (head.kind !== 'episode' || (i.season ?? -1) === (head.season ?? -1)));
            await Scraper.applyHit(config, head.kind, items, hit.id, hit);
            if (items.length > 0) {
              store.save();
            }
          }
        } catch (err) {
          // 单条失败不中断整体
          hilog.warn(DOMAIN, 'HPVPlayer', 'rescrape item failed: %{public}s', JSON.stringify(err));
        }
        done++;
        if (onProgress !== undefined) {
          onProgress({ done: done, total: keys.length, current: head.title });
        }
        await Scraper.sleep(INTER_QUERY_MS);
      }
    } finally {
      Scraper.running = false;
    }
    return matched;
  }

  /**
   * 手动搜索一个分组：按用户输入的关键词查 TMDB，返回候选列表（不写库）。
   */
  static async searchCandidates(query: string, isTv: boolean): Promise<ScrapeCandidate[]> {
    const config = await SettingsStore.getScrapeConfig();
    if (config.apiKey.length === 0) {
      throw new Error('未配置 TMDB API Key（设置 → 刮削）');
    }
    const hits: TmdbHit[] = isTv ?
      await TmdbClient.searchTv(config, query) :
      await TmdbClient.searchMovie(config, query);
    const candidates: ScrapeCandidate[] = [];
    for (const hit of hits.slice(0, 10)) {
      candidates.push({
        tmdbId: hit.id,
        title: hit.title,
        year: hit.year,
        overview: hit.overview,
        rating: hit.rating,
        posterPath: hit.posterPath,
        backdropPath: hit.backdropPath,
        releaseDate: hit.releaseDate,
      });
    }
    return candidates;
  }

  /** 把手动选中的候选应用到分组（下载海报、拉详情、写库） */
  static async applyCandidate(param: DetailParam, items: VideoItem[],
    candidate: ScrapeCandidate): Promise<void> {
    const config = await SettingsStore.getScrapeConfig();
    const posterLocal = await TmdbClient.downloadImage(candidate.posterPath, 'w500');
    const backdropLocal = await TmdbClient.downloadImage(candidate.backdropPath, 'w780');
    const hit: ScrapedMeta = {
      id: candidate.tmdbId,
      title: candidate.title,
      overview: candidate.overview,
      rating: candidate.rating,
      releaseDate: candidate.releaseDate,
      year: candidate.year,
      posterLocal: posterLocal,
      backdropLocal: backdropLocal,
      tmdbSource: true,
    };
    await Scraper.applyHit(config, param.kind, items, candidate.tmdbId, hit);
    LibraryStore.get().save();
  }

  /** 命中结果写回整组：基础元数据 + 详情（TMDB）或分集（Bangumi） */
  private static async applyHit(config: ScrapeConfig, kind: ItemKind, items: VideoItem[],
    tmdbId: number, hit: ScrapedMeta): Promise<void> {
    if (items.length === 0) {
      return;
    }
    const type: 'movie' | 'tv' = kind === 'episode' ? 'tv' : 'movie';
    let details: TmdbDetails | null = null;
    let episodeTitles: Map<number, string> | null = null;
    try {
      if (hit.tmdbSource) {
        details = await TmdbClient.getDetails(config, tmdbId, type);
        if (kind === 'episode') {
          const season = items[0].season ?? 1;
          episodeTitles = await TmdbClient.getSeasonEpisodes(config, tmdbId, season);
        }
      } else if (kind === 'episode' && hit.id > 0) {
        // Bangumi：拉分集标题
        const eps = await BangumiClient.getEpisodes(hit.id);
        const map = new Map<number, string>();
        for (const e of eps) {
          if (e.title.length > 0) {
            map.set(e.ep, e.title);
          }
        }
        episodeTitles = map.size > 0 ? map : null;
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'HPVPlayer', 'get details failed: %{public}s', JSON.stringify(err));
    }
    for (const item of items) {
      item.matched = true;
      if (hit.tmdbSource) {
        item.tmdbId = tmdbId;
        item.tmdbType = type;
      }
      // 用规范标题覆盖本地解析标题（刮削/匹配后标题统一）；
      // 详情接口的标题最规范，其次搜索结果标题
      let finalTitle = hit.title;
      if (details !== null && details.title.length > 0) {
        finalTitle = details.title;
      }
      if (finalTitle.length > 0) {
        item.title = finalTitle;
      }
      // 未识别条目匹配电影后归一为 movie，否则 getGroupItems 仍按文件名匹配旧组
      if (item.kind === 'unknown') {
        item.kind = kind === 'episode' ? 'episode' : 'movie';
      }
      item.overview = hit.overview;
      item.rating = hit.rating;
      item.releaseDate = hit.releaseDate;
      if (hit.year > 0) {
        item.year = hit.year;
      }
      if (hit.posterLocal.length > 0) {
        item.posterFile = hit.posterLocal;
      }
      if (hit.backdropLocal.length > 0) {
        item.backdropFile = hit.backdropLocal;
      }
      if (details !== null) {
        item.cast = details.cast;
        item.runtime = details.runtime;
        item.genres = details.genres;
      }
      if (episodeTitles !== null) {
        const epNo = item.episode;
        const name = epNo !== undefined ? episodeTitles.get(epNo) : undefined;
        if (name !== undefined) {
          item.episodeTitle = name;
        }
      }
    }
  }

  private static async scrapeOne(config: ScrapeConfig,
    head: VideoItem): Promise<ScrapedMeta | null> {
    // 动漫优先 Bangumi（国内覆盖更好），miss 或关闭时回落 TMDB
    if (config.bangumiEnabled && head.kind === 'episode' &&
      NameParser.looksLikeAnime(head.name, head.title)) {
      try {
        const bgm = await Scraper.scrapeBangumi(head);
        if (bgm !== null) {
          return bgm;
        }
      } catch (err) {
        hilog.warn(DOMAIN, 'HPVPlayer', 'bangumi scrape failed, fallback tmdb: %{public}s',
          JSON.stringify(err));
      }
    }

    const isTv = head.kind === 'episode';
    const year = head.year !== undefined && head.year > 1900 ? head.year : undefined;
    let hits: TmdbHit[] = isTv ?
      await TmdbClient.searchTv(config, head.title, year) :
      await TmdbClient.searchMovie(config, head.title, year);
    // 带年份无结果时放宽再试
    if (hits.length === 0 && year !== undefined) {
      hits = isTv ?
        await TmdbClient.searchTv(config, head.title) :
        await TmdbClient.searchMovie(config, head.title);
    }
    if (hits.length === 0) {
      return null;
    }
    const hit = hits[0];
    const posterLocal = await TmdbClient.downloadImage(hit.posterPath, 'w500');
    const backdropLocal = await TmdbClient.downloadImage(hit.backdropPath, 'w780');
    return {
      id: hit.id,
      title: hit.title,
      overview: hit.overview,
      rating: hit.rating,
      releaseDate: hit.releaseDate,
      year: hit.year,
      posterLocal: posterLocal,
      backdropLocal: backdropLocal,
      tmdbSource: true,
    };
  }

  /** Bangumi 刮削（动漫） */
  private static async scrapeBangumi(head: VideoItem): Promise<ScrapedMeta | null> {
    const results = await BangumiClient.searchAnime(head.title);
    if (results.length === 0) {
      return null;
    }
    const subject = results[0];
    const posterLocal = await BangumiClient.downloadImage(subject.images?.large ??
      subject.images?.common ?? '');
    return {
      id: subject.id ?? 0,
      title: (subject.name_cn ?? '').length > 0 ? subject.name_cn as string :
        (subject.name ?? head.title),
      overview: subject.summary ?? '',
      rating: subject.rating?.score ?? 0,
      releaseDate: subject.date ?? '',
      year: (subject.date ?? '').length >= 4 ? parseInt((subject.date as string).substring(0, 4)) : 0,
      posterLocal: posterLocal,
      backdropLocal: '',
      tmdbSource: false,
    };
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(resolve, ms));
  }
}

interface ScrapedMeta {
  id: number;
  title: string;
  overview: string;
  rating: number;
  releaseDate: string;
  year: number;
  posterLocal: string;
  backdropLocal: string;
  /** true=TMDB（tmdbId 可用），false=Bangumi（id 为 bgm subjectId） */
  tmdbSource: boolean;
}
