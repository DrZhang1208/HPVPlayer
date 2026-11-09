/**
 * HPVPlayer - M3U/M3U8 播放列表解析。
 *
 * #EXTM3U / #EXTINF:<duration>,<title> 条目，相对路径基于列表 URL 解析。
 */
import { url } from '@kit.ArkTS';

export interface PlaylistItem {
  url: string;
  title: string;
}

export class PlaylistParser {
  /**
   * 解析 m3u/m3u8 文本。
   * @param text      列表文本内容
   * @param baseUrl   列表文件的 URL，用于解析相对路径
   */
  static parseM3U(text: string, baseUrl: string): PlaylistItem[] {
    const items: PlaylistItem[] = [];
    const lines = text.split(/\r?\n/);
    let pendingTitle = '';
    for (const rawLine of lines) {
      const line = rawLine.trim();
      if (line.length === 0) {
        continue;
      }
      if (line.startsWith('#')) {
        if (line.startsWith('#EXTINF:')) {
          // #EXTINF:<duration>,<title>
          const comma = line.indexOf(',');
          pendingTitle = comma >= 0 ? line.substring(comma + 1).trim() : '';
        }
        continue;
      }
      const absolute = PlaylistParser.resolve(line, baseUrl);
      if (absolute !== null) {
        items.push({ url: absolute, title: pendingTitle });
      }
      pendingTitle = '';
    }
    return items;
  }

  /** 相对路径 → 绝对 URL；本身是绝对 URL 或本地路径则原样返回 */
  static resolve(entry: string, baseUrl: string): string | null {
    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(entry)) {
      return entry;
    }
    try {
      const base = new url.URL(baseUrl);
      const resolved = new url.URL(entry, base);
      return resolved.toString();
    } catch (err) {
      return null;
    }
  }
}
