/**
 * HPVPlayer - WebDAV 客户端（rcp / Remote Communication Kit）。
 *
 * PROPFIND 目录列表 + GET 文本（m3u 播放列表），播放本身走 mpv 的 http 栈
 * （Authorization 头由调用方通过 Media.httpHeaders 传入）。
 */
import rcp from '@hms.collaboration.rcp';
import { util } from '@kit.ArkTS';
import { DavServer } from './SettingsStore';
import { MediaTypes } from './MediaTypes';

export interface DavEntry {
  name: string;
  isDir: boolean;
  size: number;
  lastModified: string;
}

const PROPFIND_BODY =
  '<?xml version="1.0" encoding="utf-8"?>' +
  '<D:propfind xmlns:D="DAV:">' +
  '<D:prop>' +
  '<D:resourcetype/><D:getcontentlength/><D:getlastmodified/>' +
  '</D:prop>' +
  '</D:propfind>';

export class WebDavClient {
  private static session: rcp.Session | null = null;

  private static getSession(): rcp.Session {
    if (WebDavClient.session === null) {
      WebDavClient.session = rcp.createSession({
        requestConfiguration: {
          transfer: {
            timeout: { connectMs: 10000, transferMs: 30000 },
            autoRedirect: true,
          },
        },
      });
    }
    return WebDavClient.session;
  }

  /** Authorization 头（播放时同样使用） */
  static authHeaders(server: DavServer): Record<string, string> {
    const headers: Record<string, string> = {};
    if (server.user.length > 0 || server.password.length > 0) {
      const bytes = util.TextEncoder.create().encodeInto(`${server.user}:${server.password}`);
      headers['Authorization'] = `Basic ${new util.Base64Helper().encodeToStringSync(bytes)}`;
    }
    return headers;
  }

  /** 供 mpv 使用的 per-file 选项（自签名证书放行） */
  static extraOptions(server: DavServer): Map<string, string> {
    const opts = new Map<string, string>();
    if (server.allowInsecure && server.url.toLowerCase().startsWith('https')) {
      opts.set('tls-verify', 'no');
    }
    return opts;
  }

  /**
   * 列出 dirUrl 目录下的子项（不含自身）。
   */
  static async propfind(server: DavServer, dirUrl: string): Promise<DavEntry[]> {
    const headers = WebDavClient.authHeaders(server);
    headers['Depth'] = '1';
    headers['Content-Type'] = 'application/xml';
    const request = new rcp.Request(dirUrl, 'PROPFIND', headers, PROPFIND_BODY);
    const response = await WebDavClient.getSession().fetch(request);
    if (response.statusCode !== 207) {
      throw new Error(`PROPFIND 失败: HTTP ${response.statusCode}`);
    }
    const xml = WebDavClient.decodeBody(response);
    const entries = WebDavClient.parseMultistatus(xml, dirUrl);
    // 目录在前，名称自然排序
    entries.sort((a: DavEntry, b: DavEntry) => {
      if (a.isDir !== b.isDir) {
        return a.isDir ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });
    return entries;
  }

  /** GET 文本内容（用于 m3u/m3u8 播放列表） */
  static async getText(server: DavServer, url: string): Promise<string> {
    const headers = WebDavClient.authHeaders(server);
    const request = new rcp.Request(url, 'GET', headers);
    const response = await WebDavClient.getSession().fetch(request);
    if (response.statusCode !== 200) {
      throw new Error(`下载失败: HTTP ${response.statusCode}`);
    }
    return WebDavClient.decodeBody(response);
  }

  /**
   * 进入子目录 / 拼接文件 URL（对名称做百分号编码）。
   */
  static joinUrl(baseUrl: string, name: string, isDir: boolean): string {
    const base = baseUrl.endsWith('/') ? baseUrl : baseUrl + '/';
    const joined = base + encodeURIComponent(name);
    return isDir ? joined + '/' : joined;
  }

  /** URL 最后一段的名称（解码后），用于面包屑/标题 */
  static lastNameOf(url: string): string {
    let path = url;
    const schemeIdx = path.indexOf('://');
    if (schemeIdx > 0) {
      path = path.substring(schemeIdx + 3);
      const slash = path.indexOf('/');
      path = slash >= 0 ? path.substring(slash + 1) : '';
    }
    path = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    const idx = path.lastIndexOf('/');
    const raw = idx >= 0 ? path.substring(idx + 1) : path;
    return WebDavClient.percentDecode(WebDavClient.xmlDecode(raw));
  }

  // ---------- 响应体与名称解码 ----------

  /**
   * 解码响应体：优先用原始字节按 BOM / XML encoding 声明解码，
   * 兜底 rcp 的 toString()。老服务器可能返回 GBK 编码的 XML。
   */
  private static decodeBody(response: rcp.Response): string {
    const body = response.body;
    if (body === undefined) {
      return response.toString() ?? '';
    }
    return WebDavClient.decodeBytes(new Uint8Array(body));
  }

  private static decodeBytes(u8: Uint8Array): string {
    // BOM
    if (u8.length >= 3 && u8[0] === 0xEF && u8[1] === 0xBB && u8[2] === 0xBF) {
      return WebDavClient.tryDecode(u8.subarray(3), 'utf-8');
    }
    if (u8.length >= 2 && u8[0] === 0xFF && u8[1] === 0xFE) {
      return WebDavClient.tryDecode(u8.subarray(2), 'utf-16le');
    }
    if (u8.length >= 2 && u8[0] === 0xFE && u8[1] === 0xFF) {
      return WebDavClient.tryDecode(u8.subarray(2), 'utf-16be');
    }
    // 无 BOM：UTF-8 优先，出现替换字符（说明不是合法 UTF-8）再按 GBK 系尝试
    const asUtf8 = WebDavClient.tryDecode(u8, 'utf-8');
    if (!WebDavClient.hasReplacementChar(asUtf8)) {
      return asUtf8;
    }
    const asGbk = WebDavClient.tryDecode(u8, 'gbk');
    if (asGbk !== null && !WebDavClient.hasReplacementChar(asGbk)) {
      return asGbk;
    }
    const asGb18030 = WebDavClient.tryDecode(u8, 'gb18030');
    if (asGb18030 !== null && !WebDavClient.hasReplacementChar(asGb18030)) {
      return asGb18030;
    }
    return asUtf8 ?? '';
  }

  private static tryDecode(bytes: Uint8Array, encoding: string): string {
    try {
      return util.TextDecoder.create(encoding).decodeToString(bytes);
    } catch (err) {
      return '';
    }
  }

  private static hasReplacementChar(s: string): boolean {
    return s.indexOf('\uFFFD') >= 0;
  }

  /**
   * 百分号解码（UTF-8 优先，GBK 兜底）。
   * WebDAV 服务器通常把中文文件名编码为 %E4%B8%AD 这类 UTF-8 百分号序列。
   */
  private static percentDecode(s: string): string {
    if (s.indexOf('%') < 0) {
      return s;
    }
    try {
      return decodeURIComponent(s);
    } catch (err) {
      // 非 UTF-8 百分号序列（如 GBK 编码的 %D6%D0），按字节解
      const bytes = WebDavClient.percentToBytes(s);
      if (bytes !== null && bytes.length > 0) {
        const asUtf8 = WebDavClient.tryDecode(bytes, 'utf-8');
        if (asUtf8 !== '' && !WebDavClient.hasReplacementChar(asUtf8)) {
          return asUtf8;
        }
        const asGbk = WebDavClient.tryDecode(bytes, 'gbk');
        if (asGbk !== '' && !WebDavClient.hasReplacementChar(asGbk)) {
          return asGbk;
        }
      }
      return s;
    }
  }

  /** 把含 %XX 序列的字符串还原为字节（非转义字符按 UTF-8 展开拼接） */
  private static percentToBytes(s: string): Uint8Array {
    const out: number[] = [];
    const encoder = util.TextEncoder.create();
    for (let i = 0; i < s.length; i++) {
      if (s[i] === '%' && i + 3 <= s.length && /^[0-9a-fA-F]{2}$/.test(s.substring(i + 1, i + 3))) {
        out.push(parseInt(s.substring(i + 1, i + 3), 16));
        i += 2;
        continue;
      }
      const encoded = encoder.encodeInto(s[i]);
      for (const b of encoded) {
        out.push(b);
      }
    }
    return new Uint8Array(out);
  }

  // ---------- XML 解析（multistatus 容忍任意命名空间前缀） ----------

  private static parseMultistatus(xml: string, requestUrl: string): DavEntry[] {
    const entries: DavEntry[] = [];
    const responseRe = /<(?:[A-Za-z0-9_.-]+:)?response(?:\s[^>]*)?>([\s\S]*?)<\/(?:[A-Za-z0-9_.-]+:)?response>/g;
    let match = responseRe.exec(xml);
    while (match !== null) {
      const block = match[1];
      const href = WebDavClient.firstTag(block, 'href');
      if (href !== null) {
        // XML 实体解码 → 百分号解码，得到真实文件名
        const decodedHref = WebDavClient.percentDecode(WebDavClient.xmlDecode(href));
        const decodedNoSlash = decodedHref.endsWith('/') ?
          decodedHref.substring(0, decodedHref.length - 1) : decodedHref;
        // 跳过目录自身：href 与请求路径一致，或同为根
        if (!WebDavClient.isSelf(decodedNoSlash, requestUrl)) {
          const isDir = new RegExp('<(?:[A-Za-z0-9_.-]+:)?collection\\s*/?>').test(block);
          let name = decodedNoSlash;
          const slash = name.lastIndexOf('/');
          if (slash >= 0) {
            name = name.substring(slash + 1);
          }
          if (name.length > 0) {
            entries.push({
              name: name,
              isDir: isDir,
              size: WebDavClient.numberTag(block, 'getcontentlength'),
              lastModified: WebDavClient.firstTag(block, 'getlastmodified') ?? '',
            });
          }
        }
      }
      match = responseRe.exec(xml);
    }
    return entries;
  }

  private static isSelf(hrefNoSlash: string, requestUrl: string): boolean {
    // 从请求 URL 提取路径部分（与 href 走相同的解码链）
    let reqPath = requestUrl;
    const schemeIdx = reqPath.indexOf('://');
    if (schemeIdx > 0) {
      reqPath = reqPath.substring(schemeIdx + 3);
      const slash = reqPath.indexOf('/');
      reqPath = slash >= 0 ? reqPath.substring(slash) : '/';
    }
    const reqDecoded = WebDavClient.percentDecode(WebDavClient.xmlDecode(
      reqPath.endsWith('/') ? reqPath.substring(0, reqPath.length - 1) : reqPath));
    if (reqDecoded === hrefNoSlash) {
      return true;
    }
    // 服务器 href 可能带完整 URL，兜底比较路径段
    const hrefPath = hrefNoSlash.indexOf('://') > 0 ? hrefNoSlash.substring(hrefNoSlash.indexOf('://') + 3) : hrefNoSlash;
    const hrefPathOnly = hrefPath.indexOf('/') >= 0 ? hrefPath.substring(hrefPath.indexOf('/')) : hrefPath;
    if (reqDecoded === hrefPathOnly) {
      return true;
    }
    if (hrefNoSlash.length === 0 && (reqDecoded === '' || reqDecoded === '/')) {
      return true;
    }
    return false;
  }

  private static firstTag(block: string, localName: string): string | null {
    const re = new RegExp(`<(?:[A-Za-z0-9_.-]+:)?${localName}(?:\\s[^>]*)?>([\\s\\S]*?)<\\/(?:[A-Za-z0-9_.-]+:)?${localName}>`);
    const m = re.exec(block);
    return m !== null ? WebDavClient.trim(m[1]) : null;
  }

  private static numberTag(block: string, localName: string): number {
    const raw = WebDavClient.firstTag(block, localName);
    if (raw === null) {
      return 0;
    }
    const n = parseInt(raw);
    return Number.isNaN(n) ? 0 : n;
  }

  private static trim(s: string): string {
    let start = 0;
    let end = s.length;
    while (start < end && (s[start] === ' ' || s[start] === '\n' || s[start] === '\r' || s[start] === '\t')) {
      start++;
    }
    while (end > start && (s[end - 1] === ' ' || s[end - 1] === '\n' || s[end - 1] === '\r' || s[end - 1] === '\t')) {
      end--;
    }
    return s.substring(start, end);
  }

  private static xmlDecode(s: string): string {
    let out = s.replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/&apos;/g, '\'');
    out = out.replace(/&#x([0-9a-fA-F]+);/g, (_m, hex: string) => WebDavClient.codePointToStr(parseInt(hex, 16)));
    out = out.replace(/&#(\d+);/g, (_m, dec: string) => WebDavClient.codePointToStr(parseInt(dec, 10)));
    // &amp; 必须最后处理
    return out.replace(/&amp;/g, '&');
  }

  /** Unicode 码点 → 字符串（处理增补平面需代理对） */
  private static codePointToStr(code: number): string {
    if (Number.isNaN(code) || code < 0) {
      return '';
    }
    if (code <= 0xFFFF) {
      return String.fromCharCode(code);
    }
    const c = code - 0x10000;
    return String.fromCharCode(0xD800 + (c >> 10), 0xDC00 + (c & 0x3FF));
  }
}
