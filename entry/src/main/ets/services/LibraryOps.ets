/**
 * HPVPlayer - 媒体库操作编排：全量扫描 + 自动刮削。
 */
import { MediaSource, VideoItem } from '../models/Library';
import { LibraryStore } from './LibraryStore';
import { Scanner, ScanProgress } from './Scanner';
import { Scraper, ScrapeProgress } from './Scraper';

export interface LibraryProgress {
  phase: 'scan' | 'scrape';
  found: number;
  done: number;
  total: number;
  current: string;
}

export class LibraryOps {
  /** 是否已在本应用生命周期内执行过自动扫描 */
  private static autoScanned = false;

  static get autoScanDone(): boolean {
    return LibraryOps.autoScanned;
  }

  /**
   * 扫描全部来源并（配置允许时）刮削新条目。
   */
  static async scanAll(onProgress?: (p: LibraryProgress) => void): Promise<void> {
    const store = LibraryStore.get();
    for (const source of store.sources) {
      const result = await Scanner.scan(source, (p: ScanProgress) => {
        if (onProgress !== undefined) {
          onProgress({
            phase: 'scan', found: p.found, done: 0, total: store.sources.length,
            current: p.current,
          });
        }
      });
      if (result.error === '') {
        store.applyScanResult(source.id, result.items);
        const updated: MediaSource = {
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
        };
        store.updateSource(updated);
      }
    }
    // 刮削
    try {
      await Scraper.scrapeAll((p: ScrapeProgress) => {
        if (onProgress !== undefined) {
          onProgress({
            phase: 'scrape', found: 0, done: p.done, total: p.total, current: p.current,
          });
        }
      });
    } catch (err) {
      // 无 Key / 网络问题：静默（设置页有提示），扫描结果不受影响
    }
  }

  /** 应用启动后首次进入自动扫描一次 */
  static async autoScanOnce(onProgress?: (p: LibraryProgress) => void): Promise<void> {
    if (LibraryOps.autoScanned) {
      return;
    }
    LibraryOps.autoScanned = true;
    const store = LibraryStore.get();
    if (store.sources.length === 0) {
      return;
    }
    await LibraryOps.scanAll(onProgress);
  }
}
