/// 注入到 WebView 的嗅探脚本。
///
/// 三条互补的路径：
/// 1. 包装 window.fetch / XMLHttpRequest.open —— 页面主动发起请求时立即命中；
/// 2. 扫描 performance 资源条目 —— 兜住脚本注入之前就已经发出的请求；
/// 3. 扫描 <video>/<source> 的 src —— 兜住直接用标签播放的页面。
///
/// 上报分两类：
/// - `playlist`：m3u8（含 master / 码率变体），可直接交给 Nerelict 播放与统一下载；
/// - `segment`：`.ts` / `.m4s` / fMP4 分片，由 Dart 侧聚合到所属视频，不单独成项。
///
/// mp4 等直链视频仍由 PlayerChannel 独立处理，保持原有播放行为不变。
/// 结果通过 JavaScriptChannel `SniffChannel` 回传给 Dart 层。
const String kSniffJs = r'''
(function () {
  if (window.__ssInjected) {
    try { window.__ssScan && window.__ssScan(); } catch (e) {}
    return;
  }
  window.__ssInjected = true;

  var seen = {};
  var segCount = 0;
  var MAX_SEG = 240;
  var playlists = {};

  var HLS = /\.m3u8(\?|#|$)/i;
  var TS = /\.(ts|m4s)(\?|#|$)/i;
  var MP4_SEG = /\.(mp4|m4v|webm)(\?|#|$)/i;
  var SEG_HINT = /(^|[\/_\-.])(seg|segment|chunk|fragment|part|init)[\/_\-.]?\d*/i;

  function absolute(u) {
    try { return new URL(u, location.href).href; } catch (e) { return u; }
  }
  function noHash(u) { return u.split('#')[0]; }
  function dirOf(u) {
    try {
      var x = new URL(u);
      return x.origin + x.pathname.replace(/[^/]*$/, '');
    } catch (e) { return ''; }
  }
  function kindOf(u) {
    var clean = u.split('?')[0].split('#')[0];
    if (HLS.test(u)) return 'playlist';
    if (TS.test(clean)) return 'segment';
    if (MP4_SEG.test(clean) && SEG_HINT.test(clean)) return 'segment';
    return '';
  }

  function report(u, from) {
    try {
      if (!u || typeof u !== 'string') return;
      if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
      var abs = absolute(u);
      if (!/^https?:/i.test(abs)) return;
      var k = kindOf(abs);
      if (!k) return;
      // 同一地址只上报一次；带不同签名的同一 m3u8 由 Dart 侧规范化去重
      var key = k + '|' + noHash(abs);
      if (seen[key]) return;
      if (k === 'segment') {
        if (segCount >= MAX_SEG) return;
        segCount++;
      }
      seen[key] = 1;

      // 分片尽量带上同目录已发现的播放列表，方便 Dart 侧精确聚合
      var d = dirOf(abs);
      var parent = playlists[d] || null;
      if (k === 'playlist' && d && !playlists[d]) playlists[d] = abs;

      SniffChannel.postMessage(JSON.stringify({
        url: abs,
        kind: k,
        from: from,
        page: location.href,
        title: (document.title || '').slice(0, 120),
        parent: parent
      }));
    } catch (e) {}
  }

  window.__ssReport = report;

  // 1. fetch
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

  // 1b. XHR
  try {
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      try { report(url, 'xhr'); } catch (e) {}
      return origOpen.apply(this, arguments);
    };
  } catch (e) {}

  // 1c. 给元素设 src 的场景
  try {
    var desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    if (desc && desc.set) {
      Object.defineProperty(HTMLMediaElement.prototype, 'src', {
        configurable: true,
        enumerable: desc.enumerable,
        get: desc.get,
        set: function (v) {
          try { report(String(v), 'media'); } catch (e) {}
          return desc.set.call(this, v);
        }
      });
    }
  } catch (e) {}

  // 2 + 3. 定期扫描
  window.__ssScan = function () {
    try { report(location.href, 'page'); } catch (e) {}
    try {
      var entries = performance.getEntriesByType('resource');
      for (var i = 0; i < entries.length; i++) {
        report(entries[i].name, 'perf');
      }
    } catch (e) {}
    try {
      var nodes = document.querySelectorAll('video, source');
      for (var j = 0; j < nodes.length; j++) {
        var s = nodes[j].currentSrc || nodes[j].src;
        if (s) report(s, 'dom');
      }
    } catch (e) {}
  };

  // 手动嗅探：重置去重表，重新扫描页面，并补充扫描标签与正文里的 m3u8 链接
  window.__ssRescan = function () {
    seen = {};
    segCount = 0;
    playlists = {};
    try { window.__ssScan(); } catch (e) {}
    try {
      var nodes = document.querySelectorAll('a[href], source[src], video[src], iframe[src]');
      for (var i = 0; i < nodes.length; i++) {
        var n = nodes[i];
        report(n.getAttribute('href') || n.getAttribute('src'), 'manual');
      }
    } catch (e) {}
    try {
      var html = document.documentElement.innerHTML || '';
      var re = /https?:[^\s"'<>]+\.m3u8[^\s"'<>]*/gi;
      var m, c = 0;
      while ((m = re.exec(html)) !== null && c < 40) {
        report(m[0], 'manual');
        c++;
      }
    } catch (e) {}
  };

  window.__ssScan();

  if (!window.__ssTimer) {
    window.__ssTimer = setInterval(function () {
      try { window.__ssScan(); } catch (e) {}
    }, 2000);
  }
})();
''';

/// 手动嗅探：由地址栏右上角入口触发，对当前页面主动重新扫描并上报。
/// 与自动嗅探共用同一套上报与聚合逻辑，因此不会产生重复资源项。
const String kManualSniffJs = r'''
(function () {
  try { window.__ssRescan && window.__ssRescan(); } catch (e) {}
})();
''';
