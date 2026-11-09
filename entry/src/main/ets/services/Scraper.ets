/**
 * HPVPlayer - 刮削编排：对未匹配条目按解析结果查询 TMDB，
 * 同标题只搜一次，结果写回媒体库并缓存海报。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VideoItem } from '../models/Library';
import { LibraryStore } from './LibraryStore';
import { ScrapeConfig, SettingsStore } from './SettingsStore';
import { TmdbClient, TmdbHit } from './TmdbClient';

const DOMAIN = 0x0000;
const INTER_QUERY_MS = 300; // TMDB 限流保护

export interface ScrapeProgress {
  done: number;
  total: number;
  current: string;
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
            for (const item of items) {
              item.matched = true;
              item.tmdbId = hit.id;
              item.tmdbType = head.kind === 'episode' ? 'tv' : 'movie';
              item.overview = hit.overview;
              item.rating = hit.rating;
              item.releaseDate = hit.releaseDate;
              if (hit.year > 0 && item.year === undefined) {
                item.year = hit.year;
              }
              if (hit.posterLocal.length > 0) {
                item.posterFile = hit.posterLocal;
              }
              if (hit.backdropLocal.length > 0) {
                item.backdropFile = hit.backdropLocal;
              }
            }
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

  private static async scrapeOne(config: ScrapeConfig,
    head: VideoItem): Promise<ScrapedMeta | null> {
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
      overview: hit.overview,
      rating: hit.rating,
      releaseDate: hit.releaseDate,
      year: hit.year,
      posterLocal: posterLocal,
      backdropLocal: backdropLocal,
    };
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(resolve, ms));
  }
}

interface ScrapedMeta {
  id: number;
  overview: string;
  rating: number;
  releaseDate: string;
  year: number;
  posterLocal: string;
  backdropLocal: string;
}
