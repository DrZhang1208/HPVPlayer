/**
 * HPVPlayer - Bangumi 番组计划客户端（开放 API，无需 Key）。
 * 文档: https://github.com/bangumi/api
 * 动漫/日剧场景国内覆盖远优于 TMDB。
 */
import { rcp } from '@kit.RemoteCommunicationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';

const DOMAIN = 0x0000;
const BASE = 'https://api.bgm.tv';
const UA = 'DrZhang1208/HPVPlayer (https://github.com/DrZhang1208/HPVPlayer)';

interface BgmSubject {
  id?: number;
  name?: string;
  name_cn?: string;
  summary?: string;
  date?: string;
  images?: BgmImages;
  rating?: BgmRating;
  eps?: number;
  platform?: number;
}

interface BgmImages {
  large?: string;
  common?: string;
  medium?: string;
}

interface BgmRating {
  score?: number;
}

interface BgmEpisode {
  id?: number;
  type?: number;
  ep?: number;
  name?: string;
  name_cn?: string;
}

interface BgmSearchResponse {
  data?: BgmSubject[];
}

interface BgmEpisodesResponse {
  data?: BgmEpisode[];
}

/** 单集信息 */
export interface BgmEpisodeInfo {
  ep: number;
  title: string;
}

export class BangumiClient {
  private static session: rcp.Session | null = null;
  private static cacheDir: string = '';

  static init(context: common.UIAbilityContext): void {
    BangumiClient.cacheDir = context.filesDir + '/artworks';
    if (!fs.accessSync(BangumiClient.cacheDir)) {
      fs.mkdirSync(BangumiClient.cacheDir, true);
    }
  }

  private static getSession(): rcp.Session {
    if (BangumiClient.session === null) {
      BangumiClient.session = rcp.createSession({
        baseAddress: BASE,
        headers: { 'User-Agent': UA, 'Accept': 'application/json' },
        requestConfiguration: { transfer: { autoRedirect: true } },
      });
    }
    return BangumiClient.session;
  }

  /**
   * 搜索条目（subject_type=2 动画）。
   * @returns Bangumi 条目数组，name 优先中文名
   */
  static async searchAnime(query: string): Promise<BgmSubject[]> {
    const url = `/search/subject/${encodeURIComponent(query)}?type=2&responseGroup=large`;
    const response = await BangumiClient.getSession().fetch(new rcp.Request(url, 'GET'));
    if (response.statusCode !== 200) {
      throw new Error(`Bangumi 请求失败: HTTP ${response.statusCode}`);
    }
    const root = JSON.parse(response.toString() ?? '{}') as BgmSearchResponse;
    return (root.data ?? []).slice(0, 10);
  }

  /** 获取条目的分集列表（type=1 正片） */
  static async getEpisodes(subjectId: number): Promise<BgmEpisodeInfo[]> {
    const url = `/v0/episodes?subject_id=${subjectId}&type=1&limit=200`;
    const response = await BangumiClient.getSession().fetch(new rcp.Request(url, 'GET'));
    if (response.statusCode !== 200) {
      throw new Error(`Bangumi 分集请求失败: HTTP ${response.statusCode}`);
    }
    const root = JSON.parse(response.toString() ?? '{}') as BgmEpisodesResponse;
    const eps: BgmEpisodeInfo[] = [];
    for (const e of root.data ?? []) {
      const no = e.ep ?? 0;
      const name = (e.name_cn ?? '').length > 0 ? e.name_cn as string : (e.name ?? '');
      if (no > 0) {
        eps.push({ ep: no, title: name });
      }
    }
    return eps;
  }

  /** 下载海报（Bangumi 图床 lain.bgm.tv），返回沙箱绝对路径；失败返回空串 */
  static async downloadImage(imageUrl: string): Promise<string> {
    if (imageUrl.length === 0 || BangumiClient.cacheDir === '') {
      return '';
    }
    try {
      const fileName = `bgm_${imageUrl.substring(imageUrl.lastIndexOf('/') + 1)}`;
      const target = `${BangumiClient.cacheDir}/${fileName}`;
      if (fs.accessSync(target)) {
        return target;
      }
      const response = await rcp.createSession().fetch(new rcp.Request(imageUrl, 'GET'));
      if (response.statusCode !== 200 || response.body === undefined) {
        return '';
      }
      const file = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, response.body);
      } finally {
        fs.closeSync(file);
      }
      return target;
    } catch (err) {
      hilog.warn(DOMAIN, 'HPVPlayer', 'bgm download image failed: %{public}s', JSON.stringify(err));
      return '';
    }
  }
}

/** Bangumi 候选（手动匹配用） */
export interface BgmCandidate {
  subjectId: number;
  title: string;
  year: number;
  overview: string;
  rating: number;
  imageUrl: string;
}
