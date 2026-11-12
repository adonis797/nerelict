/// 注入到 WebView 的「可播放视频」探测脚本。
///
/// 与 kSniffJs 互相独立：SniffChannel 只负责 m3u8 嗅探下载列表，
/// PlayerChannel 负责发现可交给 Nerelict 播放的视频地址
/// （m3u8 / mp4 等直链），两者互不干扰。
///
/// 判定策略（尽量少误触发普通网页浏览）：
/// 1. m3u8：fetch / XHR / performance 资源 / video 标签 / 页面地址本身，任一命中即可；
/// 2. mp4 等直链：只认 <video>/<source> 的 src 和页面地址本身，
///    避免把页面里的广告 mp4 当成主视频；
/// 3. 过滤 blob: / data: 这类无法交给播放器打开的地址；
/// 4. 同一地址在页面内只上报一次，Dart 侧再做一次「每个页面只自动接管一次」。
const String kPlayerProbeJs = r'''
(function () {
  if (window.__ssPlayerInjected) {
    try { window.__ssPlayerScan && window.__ssPlayerScan(); } catch (e) {}
    return;
  }
  window.__ssPlayerInjected = true;

  var sent = {};
  // 可交给系统播放器的封装：HLS / DASH 走任意来源；其他直链只认 DOM 与页面地址
  var VIDEO = /\.(m3u8|mpd|mp4|m4v|mov|webm|mkv|flv|3gp|m2ts)(\?|#|$)/i;
  var STREAM = /\.(m3u8|mpd)(\?|#|$)/i;

  function absolute(u) {
    try { return new URL(u, location.href).href; } catch (e) { return u; }
  }

  function report(u, from) {
    try {
      if (!u || typeof u !== 'string') return;
      if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
      if (!VIDEO.test(u)) return;
      var abs = absolute(u);
      if (!abs || abs.indexOf('http') !== 0) return;
      if (!STREAM.test(abs) && from !== 'dom' && from !== 'page') return;
      if (sent[abs]) return;
      sent[abs] = 1;
      PlayerChannel.postMessage(JSON.stringify({
        url: abs,
        from: from,
        page: location.href,
        title: (document.title || '').slice(0, 120),
        isHls: STREAM.test(abs) ? 1 : 0
      }));
    } catch (e) {}
  }

  window.__ssPlayerReport = report;

  // 1. fetch（hls.js / video.js 常用）
  try {
    var origFetch = window.fetch;
    if (origFetch) {
      window.fetch = function (input) {
        try {
          var u = (typeof input === 'string') ? input : (input && input.url);
          report(u, 'fetch');
        } catch (e) {}
        return origFetch.apply(this, arguments);
      };
    }
  } catch (e) {}

  // 2. XHR
  try {
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      try { report(url, 'xhr'); } catch (e) {}
      return origOpen.apply(this, arguments);
    };
  } catch (e) {}

  // 3. 给 <video> 设置 src 的场景
  try {
    var desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    if (desc && desc.set) {
      Object.defineProperty(HTMLMediaElement.prototype, 'src', {
        configurable: true,
        enumerable: desc.enumerable,
        get: desc.get,
        set: function (v) {
          try { report(String(v), 'dom'); } catch (e) {}
          return desc.set.call(this, v);
        }
      });
    }
  } catch (e) {}

  window.__ssPlayerScan = function () {
    try { report(location.href, 'page'); } catch (e) {}
    try {
      var entries = performance.getEntriesByType('resource');
      for (var i = 0; i < entries.length; i++) {
        report(entries[i].name, 'perf');
      }
    } catch (e) {}
    try {
      var vids = document.querySelectorAll('video');
      for (var j = 0; j < vids.length; j++) {
        var v = vids[j];
        var s = v.currentSrc || v.src;
        if (s) report(s, 'dom');
        var srcs = v.querySelectorAll('source');
        for (var k = 0; k < srcs.length; k++) {
          if (srcs[k].src) report(srcs[k].src, 'dom');
        }
      }
    } catch (e) {}
  };

  window.__ssPlayerScan();

  if (!window.__ssPlayerTimer) {
    window.__ssPlayerTimer = setInterval(function () {
      try { window.__ssPlayerScan(); } catch (e) {}
    }, 2500);
  }
})();
''';

/// 打开 Nerelict 前，暂停网页里所有 <video>，避免同时出声
const String kPauseWebVideosJs = r'''
(function () {
  try {
    var vids = document.querySelectorAll('video');
    for (var i = 0; i < vids.length; i++) {
      try { vids[i].pause(); vids[i].muted = true; } catch (e) {}
    }
  } catch (e) {}
})();
''';

/// 读取当前页面声明的网站图标：收藏时自动识别并保存，
/// 依次尝试 <link rel="icon">、apple-touch-icon、最后的 /favicon.ico。
const String kPageIconJs = r'''
(function () {
  try {
    var sel = [
      'link[rel~="icon"]',
      'link[rel="shortcut icon"]',
      'link[rel="apple-touch-icon"]',
      'link[rel="apple-touch-icon-precomposed"]',
      'meta[property="og:image"]'
    ];
    for (var i = 0; i < sel.length; i++) {
      var nodes = document.querySelectorAll(sel[i]);
      for (var j = 0; j < nodes.length; j++) {
        var href = nodes[j].getAttribute('href') ||
                   nodes[j].getAttribute('content');
        if (href) return href;
      }
    }
    return location.origin + '/favicon.ico';
  } catch (e) {
    return '';
  }
})();
''';
