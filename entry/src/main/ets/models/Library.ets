/**
 * HPVPlayer - 媒体库数据模型（来源 + 条目）。
 */

export type SourceType = 'local' | 'webdav';
export type ItemKind = 'movie' | 'episode' | 'unknown';

export interface MediaSource {
  id: string;
  type: SourceType;
  name: string;
  /** local: 用户选择的目录 URI（file://docs/...），已持久授权 */
  folderUri?: string;
  /** webdav */
  url?: string;
  user?: string;
  password?: string;
  allowInsecure?: boolean;
  /** webdav 递归扫描深度，默认 3 */
  scanDepth?: number;
  /** 上次扫描完成时间戳（毫秒），0=未扫描 */
  lastScanTs: number;
}

export interface VideoItem {
  id: string;
  sourceId: string;
  /** local: file:// URI；webdav: 完整 http(s) URL */
  uri: string;
  /** 原始文件名 */
  name: string;
  size: number;
  mtime: number;
  /** NameParser 解析结果 */
  title: string;
  year?: number;
  season?: number;
  episode?: number;
  /** TMDB 匹配到的集标题（剧集） */
  episodeTitle?: string;
  kind: ItemKind;
  /** 刮削状态 */
  matched: boolean;
  tmdbId?: number;
  tmdbType?: 'movie' | 'tv';
  overview?: string;
  rating?: number;
  releaseDate?: string;
  /** 演员表（前 N 位，"名字 饰 角色"） */
  cast?: string[];
  /** 电影时长/剧集单集时长（分钟） */
  runtime?: number;
  /** 类型标签（动作/科幻…） */
  genres?: string[];
  /** 沙箱内的海报/背景图文件路径 */
  posterFile?: string;
  backdropFile?: string;
  /** 入库时间 */
  addedTs: number;
}

/** 详情页参数：按 title(+season) 分组的键 */
export interface DetailParam {
  title: string;
  kind: ItemKind;
  /** episode 分组时的季号（-1=未知季） */
  season: number;
}

/** 分组视图模型（海报墙单元）：一个标题 = 一张卡片 */
export interface LibraryGroup {
  title: string;
  kind: ItemKind;
  season: number;
  year: number;
  posterFile: string;
  items: VideoItem[];
  addedTs: number;
  /** 聚合的元数据（取组内首个非空） */
  overview: string;
  rating: number;
  cast: string[];
  runtime: number;
  genres: string[];
}

export function sourceItemCount(items: VideoItem[], sourceId: string): number {
  let n = 0;
  for (const item of items) {
    if (item.sourceId === sourceId) {
      n++;
    }
  }
  return n;
}
