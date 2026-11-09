/**
 * Copyright (C) 2026 Bao Han <erbws@qq.com>
 */

export interface MediaOptions {
  /**
   * HTTP headers.
   */
  httpHeaders?: Map<string, string>;
  /**
   * Media start position.
   */
  start?: number;
  /**
   * Media end position.
   */
  end?: number;
  /**
   * Extra per-file mpv options, e.g. "tls-verify" -> "no".
   */
  extraOptions?: Map<string, string>;
}

export class Media {
  /**
   * Media uri.
   */
  uri: string;
  /**
   * HTTP headers.
   */
  httpHeaders?: Map<string, string>;
  /**
   * Media start position.
   */
  start?: number;
  /**
   * Media end position.
   */
  end?: number;
  /**
   * Extra per-file mpv options, e.g. "tls-verify" -> "no".
   */
  extraOptions?: Map<string, string>;

  /**
   * Creates a media for playback.
   *
   * @param uri           Media uri.
   * @param options       HTTP headers, start position, end position and extra per-file options, optional.
   */
  constructor(uri: string, options: MediaOptions = {}) {
    this.uri = uri;
    this.httpHeaders = options.httpHeaders;
    this.start = options.start;
    this.end = options.end;
    this.extraOptions = options.extraOptions;
  }
}
