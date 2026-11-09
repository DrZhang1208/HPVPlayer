/**
 * HPVPlayer - 视频文件名解析：标题 / 年份 / 季集。
 *
 * 支持 SxxExx、第X季第Y集、N x N 三种剧集标记与中英文噪声词清理。
 */
import { ItemKind } from '../models/Library';

export interface ParsedName {
  title: string;
  year?: number;
  season?: number;
  episode?: number;
  kind: ItemKind;
}

interface EpisodeMatch {
  season: number;
  episode: number;
  index: number;
}

const NOISE_WORDS: string[] = [
  '2160p', '1080p', '1080i', '720p', '480p', '4k', '8k',
  'hdr10+', 'hdr10', 'hdr', 'dv', 'dolby vision', 'dolby',
  'web-dl', 'webdl', 'webrip', 'web', 'hdtv', 'bluray', 'blu-ray',
  'brrip', 'bdrip', 'hdrip', 'dvdrip', 'remux', 'repack', 'proper',
  'extended', 'unrated', 'complete', 'limited', 'internal',
  'x264', 'x265', 'h264', 'h265', 'hevc', 'avc', 'av1',
  'xvid', 'divx', 'avc1', 'hi10p', '10bit', '8bit', '60fps', '120fps',
  'aac', 'aac2', 'aac5', 'flac', 'dts', 'dtshd', 'ac3', 'eac3', 'truehd', 'atmos',
  'dual audio', 'multi audio', '2audio', '3audio', 'multi',
  'chs', 'cht', 'chs&eng', 'cht&eng', '简体中文', '繁体中文', '简体', '繁体',
  '中字', '中英双字', '中英文字幕', '国语', '粤语', '英语', '日语', '内嵌字幕', '内封字幕',
  'yyds', 'ade', 'ade-web', 'ttg', 'hdhome', 'chdbits', 'ourbits',
];

const CN_DIGITS: Record<string, number> = {
  '一': 1, '二': 2, '三': 3, '四': 4, '五': 5,
  '六': 6, '七': 7, '八': 8, '九': 9, '十': 10, '零': 0,
};

function cnNumberToDigit(s: string): number {
  if (/^\d+$/.test(s)) {
    return parseInt(s);
  }
  // 十 / 一~九 / 十一~十九 / 二十 / 二十一
  if (s === '十') {
    return 10;
  }
  const shi = s.indexOf('十');
  if (shi < 0) {
    return CN_DIGITS[s] ?? -1;
  }
  const head = s.substring(0, shi);
  const tail = s.substring(shi + 1);
  const tens = head.length === 0 ? 1 : (CN_DIGITS[head] ?? -1);
  const ones = tail.length === 0 ? 0 : (CN_DIGITS[tail] ?? -1);
  if (tens < 0 || ones < 0) {
    return -1;
  }
  return tens * 10 + ones;
}

function findEpisode(s: string): EpisodeMatch | null {
  // S02E03 / s2 e3（允许多集 S02E03-E04 取首集）
  let m = /[\s._\-\[]s(\d{1,2})[\s._\-]?e(\d{1,3})(?:[\-~][es]?\d{1,3})?[\s._\-\]]?/i.exec(s);
  if (m !== null && m.index !== undefined) {
    return { season: parseInt(m[1]), episode: parseInt(m[2]), index: m.index };
  }
  // 第2季第5集 / 第二季 第十三话 / 第2季03
  m = /第\s*(\d{1,2}|[一二三四五六七八九十]{1,3})\s*季\s*(?:第\s*)?(\d{1,3}|[一二三四五六七八九十]{1,3})\s*[集话話]?/.exec(s);
  if (m !== null && m.index !== undefined) {
    const season = cnNumberToDigit(m[1]);
    const episode = cnNumberToDigit(m[2]);
    if (season > 0 && episode > 0) {
      return { season: season, episode: episode, index: m.index };
    }
  }
  // EP05 / E05（无季标记，默认第 1 季）
  m = /[\s._\[]e(?:p)?\.?(\d{1,3})(?=[\s._\]\)])/i.exec(s);
  if (m !== null && m.index !== undefined) {
    return { season: 1, episode: parseInt(m[1]), index: m.index };
  }
  // 4x12
  m = /[\s._\[](\d{1,2})x(\d{1,3})[\s._\]]/.exec(s);
  if (m !== null && m.index !== undefined) {
    return { season: parseInt(m[1]), episode: parseInt(m[2]), index: m.index };
  }
  // 动漫风格 " - 05"
  m = /\s-\s(\d{1,3})(?=[\s._\]\)]|$)/.exec(s);
  if (m !== null && m.index !== undefined) {
    return { season: 1, episode: parseInt(m[1]), index: m.index };
  }
  return null;
}

function findYear(s: string): number | undefined {
  // 括号内年份优先
  let m = /[\(\[（【\.](19\d{2}|20\d{2})[\)\]）】\.]/.exec(s);
  if (m !== null) {
    return parseInt(m[1]);
  }
  m = /[\s._](19\d{2}|20\d{2})(?=[\s._]|$)/.exec(s);
  if (m !== null) {
    return parseInt(m[1]);
  }
  return undefined;
}

function cleanTitle(s: string): string {
  let out = s;
  // 去 [...] {...} 整块（发布组/站点标记）
  out = out.replace(/[\[\{【][^\]\}】]*[\]\}】]/g, ' ');
  // 分隔符归一
  out = out.replace(/[._]+/g, ' ');
  // 逐词去噪声（大小写不敏感，整词）
  for (const word of NOISE_WORDS) {
    const re = new RegExp(`(^|\\s)${word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?=\\s|$)`, 'gi');
    out = out.replace(re, ' ');
  }
  // 合并空白
  out = out.replace(/\s+/g, ' ').trim();
  // 常见残留分隔符
  out = out.replace(/^[\-\s]+|[\-\s]+$/g, '');
  return out;
}

export class NameParser {
  /**
   * 解析文件名（不含扩展名）。
   */
  static parse(fileName: string): ParsedName {
    const name = fileName.trim();
    const episode = findEpisode(name);
    const year = findYear(name);

    // 标题 = 季集标记/年份之前的最早截断点
    let cut = name.length;
    if (episode !== null) {
      cut = Math.min(cut, episode.index);
    }
    if (year !== undefined) {
      const yearIdx = name.indexOf(`${year}`);
      if (yearIdx > 0) {
        cut = Math.min(cut, yearIdx);
      }
    }
    let title = name.substring(0, cut);
    title = cleanTitle(title);
    if (title.length === 0) {
      // 截断点太靠前（如以年份开头），尝试清理全名
      const fallback = cleanTitle(name);
      if (fallback.length > 0) {
        title = fallback;
      } else {
        return { title: name, kind: 'unknown' };
      }
    }

    if (episode !== null) {
      return {
        title: title,
        year: year,
        season: episode.season,
        episode: episode.episode,
        kind: 'episode',
      };
    }
    return { title: title, year: year, kind: 'movie' };
  }
}
