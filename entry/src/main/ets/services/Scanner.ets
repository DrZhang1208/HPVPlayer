/**
 * HPVPlayer - 媒体库扫描。
 *
 * local: 用户授权的文件夹 URI 递归枚举（fs.listFileSync 对 URI 的支持
 *        因系统版本而异，采用 URI 直传 → docs URI 映射真实路径 双策略）
 * webdav: PROPFIND 递归（深度受 scanDepth 限制）
 */
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MediaSource, VideoItem } from '../models/Library';
import { LibraryStore } from './LibraryStore';
import { MediaTypes } from './MediaTypes';
import { NameParser } from './NameParser';
import { DavEntry, WebDavClient } from './WebDavClient';

const DOMAIN = 0x0000;
const MIN_FILE_BYTES = 5 * 1024 * 1024; // 过滤样本/广告小文件
const MAX_ITEMS = 5000;
const MAX_DIRS = 500;

export interface ScanProgress {
  found: number;
  current: string;
}

interface DavQueueItem {
  url: string;
  depth: number;
}

interface FileStatLite {
  size: number;
  mtime: number;
}

export interface ScanResult {
  items: VideoItem[];
  error: string;
}

/** file://docs/storage/Users/currentUser/X → /storage/Users/currentUser/X */
function docsUriToPath(uri: string): string {
  let rest = uri;
  const idx = rest.indexOf('://');
  if (idx > 0) {
    rest = rest.substring(idx + 3);
  }
  if (rest.startsWith('docs/')) {
    rest = rest.substring('docs'.length);
  }
  try {
    return decodeURIComponent(rest);
  } catch (err) {
    return rest;
  }
}

/** 仅用于进度展示：解码 %XX 中文；完整 URL 太长时只保留路径段 */
function displayPath(url: string): string {
  let text = url;
  try {
    text = decodeURIComponent(url);
  } catch (err) {
    // 保留原样
  }
  // 去掉协议与主机，只留路径，避免进度行过长
  const schemeIdx = text.indexOf('://');
  if (schemeIdx > 0) {
    const slashIdx = text.indexOf('/', schemeIdx + 3);
    if (slashIdx > 0) {
      text = text.substring(slashIdx + 3, slashIdx) + text.substring(slashIdx);
    }
  }
  return text;
}

export class Scanner {
  static async scan(source: MediaSource,
    onProgress?: (p: ScanProgress) => void): Promise<ScanResult> {
    try {
      const items = source.type === 'local' ?
        await Scanner.scanLocal(source, onProgress) :
        await Scanner.scanWebDav(source, onProgress);
      return { items: items, error: '' };
    } catch (err) {
      hilog.error(DOMAIN, 'HPVPlayer', 'scan failed: %{public}s', JSON.stringify(err));
      const msg = (err as BusinessError).message ?? JSON.stringify(err);
      return { items: [], error: msg };
    }
  }

  // ---------- 本地文件夹 ----------

  private static async scanLocal(source: MediaSource,
    onProgress?: (p: ScanProgress) => void): Promise<VideoItem[]> {
    const rootUri = source.folderUri ?? '';
    if (rootUri.length === 0) {
      throw new Error('来源缺少目录');
    }
    const items: VideoItem[] = [];
    const queue: string[] = [rootUri];
    let dirCount = 0;

    while (queue.length > 0 && items.length < MAX_ITEMS && dirCount < MAX_DIRS) {
      const dir = queue.shift()!;
      dirCount++;
      if (onProgress !== undefined) {
        onProgress({ found: items.length, current: displayPath(dir) });
      }
      const children = Scanner.listDir(dir);
      for (const child of children) {
        if (items.length >= MAX_ITEMS) {
          break;
        }
        const childUri = Scanner.joinDir(dir, child);
        if (child.startsWith('.') || child.startsWith('._')) {
          continue;
        }
        if (Scanner.isDirectory(childUri)) {
          if (dirCount + queue.length < MAX_DIRS) {
            queue.push(childUri);
          }
          continue;
        }
        const stat = Scanner.statOf(childUri);
        if (!MediaTypes.isVideo(child)) {
          continue; // 媒体库只收视频
        }
        if (stat.size > 0 && stat.size < MIN_FILE_BYTES) {
          continue; // 样本/广告/字幕镜像等小文件
        }
        items.push(Scanner.buildItem(source, childUri, child, stat.size, stat.mtime));
        if (onProgress !== undefined) {
          onProgress({ found: items.length, current: child });
        }
      }
    }
    return items;
  }

  /**
   * 枚举目录：策略一 listFileSync(URI)；失败走策略二
   * （docs URI → 真实路径映射，与 mpv 播放使用的映射一致）。
   */
  private static listDir(dir: string): string[] {
    try {
      return fs.listFileSync(dir).sort();
    } catch (err) {
      hilog.info(DOMAIN, 'HPVPlayer', 'listFileSync(uri) failed, fallback to mapped path');
    }
    if (dir.startsWith('file://')) {
      try {
        return fs.listFileSync(docsUriToPath(dir)).sort();
      } catch (err) {
        hilog.error(DOMAIN, 'HPVPlayer', 'listFileSync(mapped) failed: %{public}s',
          JSON.stringify(err));
        throw new Error(`无法读取目录: ${dir}`);
      }
    }
    throw new Error(`无法读取目录: ${dir}`);
  }

  private static joinDir(dir: string, name: string): string {
    const base = dir.endsWith('/') ? dir : dir + '/';
    return base + name;
  }

  private static isDirectory(path: string): boolean {
    try {
      return fs.statSync(path).isDirectory();
    } catch (err) {
      return false;
    }
  }

  private static statOf(path: string): FileStatLite {
    try {
      const stat = fs.statSync(path);
      const out: FileStatLite = { size: stat.size, mtime: stat.mtime };
      return out;
    } catch (err) {
      const empty: FileStatLite = { size: 0, mtime: 0 };
      return empty;
    }
  }

  // ---------- WebDAV ----------

  private static async scanWebDav(source: MediaSource,
    onProgress?: (p: ScanProgress) => void): Promise<VideoItem[]> {
    const server = LibraryStore.sourceToDavServer(source);
    const maxDepth = source.scanDepth ?? 3;
    const items: VideoItem[] = [];
    const root: DavQueueItem = { url: server.url, depth: 0 };
    const queue: DavQueueItem[] = [root];
    let dirCount = 0;

    while (queue.length > 0 && items.length < MAX_ITEMS && dirCount < MAX_DIRS) {
      const next = queue.shift()!;
      dirCount++;
      if (onProgress !== undefined) {
        onProgress({ found: items.length, current: displayPath(next.url) });
      }
      const entries: DavEntry[] = await WebDavClient.propfind(server, next.url);
      for (const entry of entries) {
        if (items.length >= MAX_ITEMS) {
          break;
        }
        if (entry.isDir) {
          if (next.depth + 1 < maxDepth && dirCount + queue.length < MAX_DIRS) {
            const child: DavQueueItem = {
              url: WebDavClient.joinUrl(next.url, entry.name, true),
              depth: next.depth + 1,
            };
            queue.push(child);
          }
          continue;
        }
        if (!MediaTypes.isVideo(entry.name)) {
          continue; // 媒体库只收视频
        }
        if (entry.size > 0 && entry.size < MIN_FILE_BYTES) {
          continue;
        }
        const url = WebDavClient.joinUrl(next.url, entry.name, false);
        items.push(Scanner.buildItem(source, url, entry.name, entry.size, 0));
      }
    }
    return items;
  }

  // ---------- 条目构建 ----------

  private static buildItem(source: MediaSource, uri: string, fileName: string,
    size: number, mtime: number): VideoItem {
    const dot = fileName.lastIndexOf('.');
    const baseName = dot > 0 ? fileName.substring(0, dot) : fileName;
    const parsed = NameParser.parse(baseName);
    const item: VideoItem = {
      id: `${source.id}:${uri}`,
      sourceId: source.id,
      uri: uri,
      name: fileName,
      size: size,
      mtime: mtime,
      title: parsed.title,
      kind: parsed.kind,
      matched: false,
      addedTs: 0,
    };
    if (parsed.year !== undefined) {
      item.year = parsed.year;
    }
    if (parsed.season !== undefined) {
      item.season = parsed.season;
    }
    if (parsed.episode !== undefined) {
      item.episode = parsed.episode;
    }
    return item;
  }
}
