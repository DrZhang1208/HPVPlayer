/**
 * HPVPlayer - 弹幕面板数据层：dandanplay 开放 API 搜索番剧/集。
 * 弹幕渲染由内置 Lua 脚本（scripts/danmaku）完成，
 * 本层只负责"搜索-选择"，选中后通过 script-message load-danmaku 驱动脚本。
 */
import { rcp } from '@kit.RemoteCommunicationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';

const DOMAIN = 0x0000;
const DEFAULT_API = 'https://danmaku-api.152468.xyz';
const UA = 'DrZhang1208/HPVPlayer (https://github.com/DrZhang1208/HPVPlayer)';

interface DandanAnime {
  animeId?: number;
  bangumiId?: string;
  animeTitle?: string;
  episodes?: DandanEpisode[];
  type?: string;
}

interface DandanEpisode {
  episodeId?: number;
  episodeTitle?: string;
}

interface DandanSearchResponse {
  success?: boolean;
  errorCode?: number;
  animes?: DandanAnime[];
}

interface DandanBangumiResponse {
  success?: boolean;
  bangumi?: DandanAnime;
}

/** /api/v2/comment 返回条目（p = "time,mode,color,..."） */
interface DandanCommentEntry {
  p?: string;
  m?: string;
  shift?: number;
}

interface DandanCommentData {
  count?: number;
  comments?: DandanCommentEntry[];
}

/** 兼容平铺 / 官方嵌套（data.comments）两种结构 */
interface DandanCommentResponse {
  success?: boolean;
  errorCode?: number;
  count?: number;
  comments?: DandanCommentEntry[];
  data?: DandanCommentData;
}

/** fetchCommentsFile 结果：沙箱内 XML 路径 + 条数 */
export interface DanmakuFileResult {
  path: string;
  count: number;
}

/** 搜索结果条目（App UI 用） */
export interface DanmakuAnimeResult {
  animeId: number;
  title: string;
  episodes: DanmakuEpisodeResult[];
}

export interface DanmakuEpisodeResult {
  episodeId: number;
  title: string;
}

export class DanmakuClient {
  private static session: rcp.Session | null = null;
  private static sessionApiBase: string = '';

  /** 读取 script-opts/danmaku.conf 中的 api_server（App 搜索与脚本渲染共用同一服务） */
  static currentApiBase(context: common.UIAbilityContext): string {
    try {
      const conf = context.filesDir + '/mpv/script-opts/danmaku.conf';
      if (fs.accessSync(conf)) {
        const text = fs.readTextSync(conf);
        for (const line of text.split('\n')) {
          const m = line.match(/^\s*api_server\s*=\s*(.+)/);
          if (m !== null) {
            const value = m[1].trim().replace(/^["']|["']$/g, '');
            const first = value.split(',')[0].split('|')[0].split('#')[0].trim();
            if (first.startsWith('http')) {
              return first;
            }
          }
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'HPVPlayer', 'read danmaku.conf failed: %{public}s', JSON.stringify(err));
    }
    return DEFAULT_API;
  }

  private static getSession(apiBase: string): rcp.Session {
    if (DanmakuClient.session === null || DanmakuClient.sessionApiBase !== apiBase) {
      DanmakuClient.session?.close();
      DanmakuClient.session = rcp.createSession({
        baseAddress: apiBase,
        headers: { 'User-Agent': UA, 'Accept': 'application/json' },
        requestConfiguration: { transfer: { autoRedirect: true } },
      });
      DanmakuClient.sessionApiBase = apiBase;
    }
    return DanmakuClient.session;
  }

  /** 按关键词搜索番剧（不含分集——该服务搜索接口 episodes 恒空） */
  static async search(context: common.UIAbilityContext,
    keyword: string): Promise<DanmakuAnimeResult[]> {
    const base = DanmakuClient.currentApiBase(context);
    const url = `/api/v2/search/anime?keyword=${encodeURIComponent(keyword)}`;
    const response = await DanmakuClient.getSession(base).fetch(new rcp.Request(url, 'GET'));
    if (response.statusCode !== 200) {
      throw new Error(`弹幕服务请求失败: HTTP ${response.statusCode}`);
    }
    const root = JSON.parse(response.toString() ?? '{}') as DandanSearchResponse;
    // 兼容服务器 success 字段可能缺失，仅在有明确失败标记时报错
    if (root.success === false) {
      throw new Error(`弹幕服务错误: ${root.errorCode ?? -1}`);
    }
    const results: DanmakuAnimeResult[] = [];
    for (const anime of (root.animes ?? []).slice(0, 8)) {
      if ((anime.animeId ?? 0) > 0) {
        results.push({
          animeId: anime.animeId as number,
          title: anime.animeTitle ?? '',
          episodes: [],
        });
      }
    }
    return results;
  }

  /** 拉取番剧分集列表（/api/v2/bangumi/{id}，展开番剧时懒加载） */
  static async fetchEpisodes(context: common.UIAbilityContext,
    animeId: number): Promise<DanmakuEpisodeResult[]> {
    const base = DanmakuClient.currentApiBase(context);
    const url = `/api/v2/bangumi/${animeId}`;
    const response = await DanmakuClient.getSession(base).fetch(new rcp.Request(url, 'GET'));
    if (response.statusCode !== 200) {
      throw new Error(`分集请求失败: HTTP ${response.statusCode}`);
    }
    const root = JSON.parse(response.toString() ?? '{}') as DandanBangumiResponse;
    const eps: DanmakuEpisodeResult[] = [];
    for (const ep of root.bangumi?.episodes ?? []) {
      if ((ep.episodeId ?? 0) > 0) {
        eps.push({
          episodeId: ep.episodeId as number,
          title: ep.episodeTitle ?? '',
        });
      }
    }
    return eps;
  }

  /**
   * 拉取整集弹幕并写成脚本可加载的 XML 文件。
   *
   * 沙箱内 Lua 脚本无法发 HTTP（无 curl，桥接受限），弹幕数据改由 App
   * 侧 rcp 拉取后落地为 dandanplay 脚本原生支持的本地弹幕文件
   * （parse_xml_danmaku 的 <d p="time,mode,size,color"> 格式），
   * 再经 script-message add-source-event 交给脚本解析渲染。
   * @returns 沙箱内 XML 文件绝对路径与弹幕条数
   */
  static async fetchCommentsFile(context: common.UIAbilityContext,
    episodeId: number): Promise<DanmakuFileResult> {
    const base = DanmakuClient.currentApiBase(context);
    const url = `/api/v2/comment/${episodeId}?withRelated=true&chConvert=0`;
    const response = await DanmakuClient.getSession(base).fetch(new rcp.Request(url, 'GET'));
    if (response.statusCode !== 200) {
      throw new Error(`弹幕请求失败: HTTP ${response.statusCode}`);
    }
    const root = JSON.parse(response.toString() ?? '{}') as DandanCommentResponse;
    if (root.success === false) {
      throw new Error(`弹幕服务错误: ${root.errorCode ?? -1}`);
    }
    // 兼容镜像把 data 平铺 / 保留 dandanplay 官方嵌套两种返回结构
    const comments: DandanCommentEntry[] = root.comments ?? root.data?.comments ?? [];
    if (comments.length === 0) {
      throw new Error('该集没有弹幕');
    }

    const lines: string[] = [];
    for (const c of comments) {
      const text = (c.m ?? '').replace(/[\x00-\x1f]/g, '');
      const fields = (c.p ?? '').split(',');
      const shift = c.shift ?? 0;
      const time = Number(fields[0]) + shift;
      const mode = Number(fields[1]);
      const color = Number(fields[2]);
      if (Number.isNaN(time) || text.length === 0) {
        continue;
      }
      // parse_xml_danmaku 的 p 顺序: time, type(mode), size, color
      const m = Number.isNaN(mode) || mode < 1 ? 1 : mode;
      const col = Number.isNaN(color) || color <= 0 ? 16777215 : color;
      lines.push(`<d p="${time},${m},25,${col}">${DanmakuClient.escapeXml(text)}</d>`);
    }
    if (lines.length === 0) {
      throw new Error('弹幕解析结果为空');
    }

    const dir = context.filesDir + '/mpv/danmaku-cache';
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir);
    }
    const path = `${dir}/ep-${episodeId}.xml`;
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, `<?xml version="1.0" encoding="UTF-8"?>\n<i>\n${lines.join('\n')}\n</i>\n`);
    } finally {
      fs.closeSync(file);
    }
    return { path: path, count: lines.length };
  }

  private static escapeXml(text: string): string {
    return text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&apos;');
  }
}
