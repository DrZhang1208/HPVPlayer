/**
 * HPVPlayer - 播放请求模型（页面间传递的纯数据）。
 */

export interface PlayItem {
  /** 播放地址：http(s) URL、相册/文档选择器 URI、沙箱路径 */
  uri: string;
  /** 展示标题（空则用地址最后一段） */
  title: string;
  /** HTTP 请求头（WebDAV Authorization 等） */
  headers?: Record<string, string>;
  /** mpv per-file 选项（tls-verify 等） */
  extraOptions?: Record<string, string>;
}

export type PlayKind = 'url' | 'local' | 'webdav';

export interface PlayRequest {
  items: PlayItem[];
  index: number;
  kind: PlayKind;
}
