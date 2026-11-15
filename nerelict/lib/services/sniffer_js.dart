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

  // ---- 请求头透传 ----
  // 一部分站点不靠 Cookie，而是靠 Authorization / X-* 鉴权。这里按白名单挑出
  // 这类头随上报一起带给 Dart；Dart 侧 HeaderPolicy 会再过滤一遍（页面脚本不
  // 可当作可信输入）。Cookie / Range / Referer / UA 由链路自己生成，必须排除，
  // 否则会覆盖掉正确的值。
  var HDR_ALLOW = /^(authorization|x-[a-z0-9!#$%&*+.^_`|~-]+|origin)$/i;
  var HDR_BLOCK = /^(cookie|set-cookie|host|content-length|content-type|content-encoding|transfer-encoding|connection|range|if-[a-z-]+|referer|user-agent|accept|accept-encoding|accept-language|pragma|cache-control|sec-[a-z-]+|te|upgrade|proxy-[a-z-]+)$/i;
  var HDR_MAX = 8;
  var HDR_VAL_MAX = 1024;
  var seenHdr = {};

  // 把 Headers / Map / [[k,v]] / 普通对象统一成 [[k,v]]
  function headersToList(src, out) {
    if (!src || !out) return;
    try {
      if (Array.isArray(src)) {
        for (var i = 0; i < src.length; i++) {
          if (src[i] && src[i].length >= 2) out.push([src[i][0], src[i][1]]);
        }
        return;
      }
      if (typeof src.forEach === 'function') {
        src.forEach(function (v, k) { out.push([k, v]); });
        return;
      }
      if (typeof src === 'object') {
        for (var k in src) out.push([k, src[k]]);
      }
    } catch (e) {}
  }

  function pickHeaders(list) {
    if (!list || !list.length) return null;
    var out = {};
    var lower = {};
    var n = 0;
    for (var i = 0; i < list.length && n < HDR_MAX; i++) {
      var name = String(list[i][0] == null ? '' : list[i][0]).trim();
      var val = String(list[i][1] == null ? '' : list[i][1]);
      if (!name || name.length > 64) continue;
      if (HDR_BLOCK.test(name) || !HDR_ALLOW.test(name)) continue;
      if (val.length > HDR_VAL_MAX) continue;
      if (val.indexOf('\n') >= 0 || val.indexOf('\r') >= 0) continue;
      val = val.trim();
      if (!val) continue;
      var low = name.toLowerCase();
      var key = lower[low] || name;
      if (!(low in lower)) { lower[low] = key; n++; }
      // 同名头后者覆盖前者：token 刷新后应该用新值
      out[key] = val;
    }
    return n > 0 ? out : null;
  }

  function post(item) {
    try { SniffChannel.postMessage(JSON.stringify(item)); } catch (e) {}
  }

  function report(u, from, hdrs) {
    try {
      if (!u || typeof u !== 'string') return;
      if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
      var abs = absolute(u);
      if (!/^https?:/i.test(abs)) return;
      var k = kindOf(abs);
      if (!k) return;
      var picked = pickHeaders(hdrs);
      // 同一地址只上报一次；带不同签名的同一 m3u8 由 Dart 侧规范化去重
      var key = k + '|' + noHash(abs);
      if (seen[key]) {
        // 首次是靠 performance 扫描发现的（只有地址、没有头），后来才被
        // fetch/XHR 命中。这时补报一次把头带上，否则这条永远 403。
        if (!picked || seenHdr[key]) return;
        seenHdr[key] = 1;
        post({
          url: abs,
          kind: k,
          from: from,
          page: location.href,
          title: (document.title || '').slice(0, 120),
          headers: picked
        });
        return;
      }
      if (k === 'segment') {
        if (segCount >= MAX_SEG) return;
        segCount++;
      }
      seen[key] = 1;
      if (picked) seenHdr[key] = 1;

      // 分片尽量带上同目录已发现的播放列表，方便 Dart 侧精确聚合
      var d = dirOf(abs);
      var parent = playlists[d] || null;
      if (k === 'playlist' && d && !playlists[d]) playlists[d] = abs;

      post({
        url: abs,
        kind: k,
        from: from,
        page: location.href,
        title: (document.title || '').slice(0, 120),
        parent: parent,
        headers: picked || undefined
      });
    } catch (e) {}
  }

  window.__ssReport = report;

  // 0. 响应体扫描：很多站点把播放地址放在 POST 的 JSON 里（/api/play、GraphQL），
  //    请求 URL 本身不带任何媒体特征，只看 URL 永远抓不到。这里读一份 response 克隆，
  //    在文本里找媒体地址。只读 json/text/xml、限 512KB，不阻塞原请求。
  var MEDIA_IN_TEXT =
    /https?:\/\/[^\s"'\\<>]+?\.(?:m3u8|mpd|mp4|m4v|mov|webm|ts|m4s)(?:\?[^\s"'\\<>]*)?/gi;

  function scanBody(text, from, hdrs) {
    try {
      if (!text || typeof text !== 'string') return;
      if (text.length > 524288) text = text.slice(0, 524288);
      // JSON 里的斜杠常被转义成 \/，先还原再匹配
      if (text.indexOf('\\/') >= 0) text = text.replace(/\\\//g, '/');
      var m = text.match(MEDIA_IN_TEXT);
      if (!m) return;
      // 能从响应体里拿到地址，说明发起这次请求的 token 对它大概率也有效，
      // 一并把请求头带过去，避免「抓到了地址但播放 403」
      for (var i = 0; i < m.length && i < 8; i++) report(m[i], from || 'body', hdrs);
    } catch (e) {}
  }

  function bodyAllowed(res) {
    try {
      if (!res || !res.ok) return false;
      var h = res.headers;
      if (!h || !h.get) return false;
      var ct = String(h.get('content-type') || '');
      if (!/json|text|xml|javascript/i.test(ct)) return false;
      var cl = parseInt(String(h.get('content-length') || '0'), 10);
      if (cl > 524288) return false;
      return typeof res.clone === 'function';
    } catch (e) { return false; }
  }

  // 1. fetch
  try {
    var origFetch = window.fetch;
    if (origFetch) {
      window.fetch = function (input, init) {
        try {
          var u = (typeof input === 'string') ? input : (input && input.url);
          // init.headers 会覆盖 Request 自带的头，所以先取后者、再取前者
          var hs = [];
          headersToList(init && init.headers, hs);
          if (!hs.length && input && typeof input === 'object') {
            headersToList(input.headers, hs);
          }
          report(u, 'fetch', hs);
        } catch (e) {}
        var p = origFetch.apply(this, arguments);
        try {
          if (p && typeof p.then === 'function') {
            p.then(function (res) {
              try {
                if (!bodyAllowed(res)) return;
                res.clone().text().then(function (t) {
                  scanBody(t, 'body', hs);
                }).catch(function () {});
              } catch (e) {}
            }).catch(function () {});
          }
        } catch (e) {}
        return p;
      };
    }
  } catch (e) {}

  // 1b. XHR
  try {
    var origSetHeader = XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
      try {
        if (!this.__ssH) this.__ssH = [];
        this.__ssH.push([String(name), String(value)]);
      } catch (e) {}
      return origSetHeader.apply(this, arguments);
    };
  } catch (e) {}

  try {
    var origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function () {
      try {
        if (this.__ssUrl) report(this.__ssUrl, 'xhr', this.__ssH);
      } catch (e) {}
      return origSend.apply(this, arguments);
    };
  } catch (e) {}

  try {
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      try {
        // setRequestHeader 只能在上报之后调用，所以这里先清空、记录地址，
        // 等 send 时再把攒到的头一起报上去
        this.__ssH = [];
        this.__ssUrl = absolute(String(url));
        report(url, 'xhr');
      } catch (e) {}
      try {
        var self = this;
        self.addEventListener('load', function () {
          try {
            if (self.status < 200 || self.status >= 300) return;
            var rt = self.responseType;
            if (rt && rt !== 'text' && rt !== 'json') return;
            var t = rt === 'json' ? JSON.stringify(self.response) : self.responseText;
            scanBody(t, 'body', self.__ssH);
          } catch (e) {}
        });
      } catch (e) {}
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
    seenHdr = {};
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
