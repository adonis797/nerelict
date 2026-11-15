/// 页面侧「点击归因」嗅探脚本。
///
/// 解决的问题：大量站点的视频要等用户点一下封面 / 剧集卡片才创建播放器并加载
/// 播放列表，「点开后在浮层弹窗里直接浮起播放窗口」是其中最常见的一种。
/// 这类资源在点击之前根本不存在，被动嗅探（fetch / performance / DOM 扫描）
/// 只能扫到页面里其它无关视频，或者一个都扫不到。
///
/// 这套脚本只做三件事，且**不拦截、不改写**页面交互：
/// 1. 在捕获阶段记录点击（pointerdown / click），开一个 8 秒的归因窗口；
/// 2. 把窗口内新出现的播放列表 / 分片请求、新插入的 `<video>`、`play()` 调用
///    都算到这次点击头上，连同点击目标的描述一起上报；
/// 3. 给播放器容器打「浮层」评分（fixed/absolute + 高 z-index + 覆盖面积 +
///    弹窗类名），达到阈值才标记成浮层播放，避免把普通内联播放器误判。
///
/// 与 kSniffJs / kPlayerProbeJs 完全独立：不碰它们的去重表，也不改它们的
/// fetch/XHR 包装，只是在外层再包一次并在窗口内旁路上报。
/// 结果通过 JavaScriptChannel `ClickChannel` 回传。
const String kClickSniffJs = r'''
(function () {
  if (window.__ssClickInjected) {
    try { window.__ssClickScan && window.__ssClickScan(); } catch (e) {}
    return;
  }
  window.__ssClickInjected = true;

  // 归因窗口：点击后 8 秒内到达的媒体请求都算这次点击
  var ATTR_MS = 8000;
  // 主动扫描的时间点：覆盖「点击 -> 动画 -> 创建播放器 -> 取流」的常见耗时
  var SWEEPS = [0, 300, 800, 1500, 2600, 4200];
  var MAX_SESSIONS = 6;
  var MAX_HITS = 24;
  var MAX_SEEN = 400;
  // 浮层判定阈值，与 Dart 侧 kOverlayThreshold 保持一致
  var OVERLAY_MIN = 50;

  var seq = 0;
  var sessions = [];
  var seen = {};
  var seenCount = 0;

  var HLS = /\.m3u8(\?|#|$)/i;
  var DASH = /\.mpd(\?|#|$)/i;
  var TS = /\.(ts|m4s)(\?|#|$)/i;
  var PROG = /\.(mp4|m4v|mov|webm|mkv|flv|3gp|m2ts)(\?|#|$)/i;
  // 弹窗 / 播放器常见的类名、id、role 片段
  var HINT = /(modal|popup|pop-up|overlay|dialog|mask|lightbox|layer|player|float|fullscreen|sheet|drawer)/i;

  function abs(u) {
    try { return new URL(u, location.href).href; } catch (e) { return ''; }
  }

  function post(obj) {
    try {
      obj.page = location.href;
      obj.title = (document.title || '').slice(0, 120);
      ClickChannel.postMessage(JSON.stringify(obj));
    } catch (e) {}
  }

  function kindOf(u) {
    if (HLS.test(u) || DASH.test(u)) return 'playlist';
    if (TS.test(u)) return 'segment';
    if (PROG.test(u)) return 'progressive';
    return '';
  }

  function live() {
    var now = Date.now();
    for (var i = sessions.length - 1; i >= 0; i--) {
      if (now - sessions[i].t0 <= ATTR_MS) return sessions[i];
    }
    return null;
  }

  function labelOf(el) {
    try {
      if (!el || !el.tagName) return '';
      var node = el;
      var txt = '';
      for (var i = 0; i < 3 && node; i++) {
        txt = String(node.innerText || node.textContent || '')
          .replace(/\s+/g, ' ').trim();
        if (txt) break;
        node = node.parentElement;
      }
      var cls = '';
      try { cls = String(el.className || '').split(/\s+/)[0] || ''; } catch (e) {}
      var out = el.tagName.toLowerCase();
      if (cls) out += '.' + cls.slice(0, 18);
      if (txt) out += ' 「' + txt.slice(0, 24) + '」';
      return out.slice(0, 48);
    } catch (e) { return ''; }
  }

  function rectOf(el) {
    try {
      var r = el.getBoundingClientRect();
      return { x: Math.round(r.left), y: Math.round(r.top),
               w: Math.round(r.width), h: Math.round(r.height) };
    } catch (e) { return { x: 0, y: 0, w: 0, h: 0 }; }
  }

  /// 浮层评分：0~100。视频本身就 30 分，固定定位 +25，铺满屏幕 +20，
  /// 有半透明遮罩 +10，类名像弹窗 +15，点击后新插入 +15。
  /// 只有达到 50 才认为「点击后浮层播放」，普通内联播放器一般停在 30~45。
  function scoreOf(el, isNew) {
    if (!el || !el.tagName) return 0;
    var vw = window.innerWidth || 360;
    var vh = window.innerHeight || 640;
    var s = 0;
    var tag = el.tagName;
    if (tag === 'VIDEO') s += 30;
    if (tag === 'IFRAME') s += 30;
    try { if (el.querySelector && el.querySelector('video')) s += 40; } catch (e) {}
    if (isNew) s += 15;

    var node = el, fixed = 0, absPos = 0, z = 0, dim = 0, i = 0, r = null;
    try { r = el.getBoundingClientRect(); } catch (e) { r = null; }
    while (node && node.nodeType === 1 && i < 6) {
      var st = null;
      try { st = window.getComputedStyle(node); } catch (e) { st = null; }
      if (st) {
        if (st.position === 'fixed') fixed = 1;
        if (st.position === 'absolute') absPos = 1;
        var zz = parseInt(st.zIndex, 10);
        if (!isNaN(zz) && zz > z) z = zz;
        // 只把「定位过的深色铺满层」当遮罩：整页深色背景不算，
        // 否则任何深色主题页面上的内联播放器都会白捡 10 分
        var positioned = st.position === 'fixed' || st.position === 'absolute';
        if (!dim && positioned && st.backgroundColor) {
          var m = /rgba?\(([^)]+)\)/.exec(st.backgroundColor);
          if (m) {
            var parts = m[1].split(',');
            var a = parts.length > 3 ? parseFloat(parts[3]) : 1;
            if (!isNaN(a) && a >= 0.45) {
              var rr = node.getBoundingClientRect();
              if (rr.width * rr.height >= vw * vh * 0.5) dim = 1;
            }
          }
        }
      }
      node = node.parentElement;
      i++;
    }
    if (fixed) s += 25;
    else if (absPos && z >= 10) s += 15;

    var area = r ? (r.width * r.height) / (vw * vh) : 0;
    if (area >= 0.55) s += 20;
    else if (area >= 0.3) s += 10;
    if (dim) s += 10;

    var hint = '';
    try {
      hint = String(el.className || '') + ' ' + String(el.id || '') +
             ' ' + String(el.getAttribute('role') || '');
    } catch (e) {}
    if (HINT.test(hint)) s += 15;

    return s > 100 ? 100 : s;
  }

  function noteOverlay(s, el, score) {
    if (!s || s.cancelled || !el || score < OVERLAY_MIN) return;
    // 同一会话只在首次越线、或分数明显提高时再报，避免动画过程中刷屏
    if (s.reported && score < s.reported + 15) return;
    s.score = score;
    s.reported = score;
    s.overlayTag = String(el.tagName || '').toLowerCase();
    var rect = rectOf(el);
    post({
      t: 'overlay', id: s.id, score: score, tag: s.overlayTag,
      cls: (function () {
        try { return String(el.className || '').slice(0, 40); } catch (e) { return ''; }
      })(),
      w: rect.w, h: rect.h
    });
    // 命中可能早于浮层判定：把本会话已捕获的地址按新分数补报一遍，
    // Dart 侧按会话去重，不会重复计入捕获次数
    for (var i = 0; i < s.order.length; i++) {
      var u = s.order[i];
      post({
        t: 'hit', id: s.id, url: u, kind: kindOf(u), from: 'overlay',
        delay: Date.now() - s.t0, score: s.score,
        overlay: s.overlayTag, label: s.label
      });
    }
  }

  function noteMse(s, from) {
    if (!s || s.mse) return;
    s.mse = 1;
    post({ t: 'mse', id: s.id, from: from });
  }

  function hit(s, raw, from) {
    if (!s || s.cancelled) return;
    if (!raw || typeof raw !== 'string') return;
    if (raw.indexOf('blob:') === 0 || raw.indexOf('data:') === 0) {
      noteMse(s, from);
      return;
    }
    var u = abs(raw);
    if (!u || u.indexOf('http') !== 0) return;
    var k = kindOf(u);
    if (!k) return;
    if (s.urls[u]) return;
    if (s.count >= MAX_HITS) return;
    s.urls[u] = 1;
    s.order.push(u);
    s.count++;

    if (!seen[u] && seenCount < MAX_SEEN) {
      seen[u] = 1;
      seenCount++;
    } else if (seenCount >= MAX_SEEN) {
      seen = {};
      seenCount = 0;
      seen[u] = 1;
      seenCount = 1;
    }

    post({
      t: 'hit', id: s.id, url: u, kind: k, from: from,
      delay: Date.now() - s.t0, score: s.score,
      overlay: s.overlayTag, label: s.label
    });
  }

  function inspectNode(s, n) {
    if (!s || !n || n.nodeType !== 1) return;
    if (n.tagName === 'VIDEO') {
      var u = '';
      try { u = n.currentSrc || n.src || ''; } catch (e) {}
      if (!u) {
        try {
          var ss = n.querySelectorAll('source');
          for (var i = 0; i < ss.length; i++) {
            if (ss[i].src) { u = ss[i].src; break; }
          }
        } catch (e) {}
      }
      if (u) hit(s, u, 'dom');
      noteOverlay(s, n, scoreOf(n, !(s.pre && s.pre.has && s.pre.has(n))));
      return;
    }
    if (n.tagName === 'IFRAME') {
      inspectFrame(s, n, true);
      return;
    }
    var v = null;
    try { v = n.querySelector && n.querySelector('video'); } catch (e) {}
    if (!v) return;
    s.cand = v;
    var byParent = scoreOf(v.parentElement || n, true);
    var bySelf = scoreOf(n, true);
    if (bySelf >= byParent) noteOverlay(s, n, bySelf);
    else noteOverlay(s, v, byParent);
  }

  function inspectFrame(s, f, isNew) {
    var src = '';
    try { src = f.src || ''; } catch (e) {}
    var doc = null;
    try { doc = f.contentDocument; } catch (e) { doc = null; }
    if (doc) {
      try {
        var vs = doc.querySelectorAll('video');
        for (var i = 0; i < vs.length; i++) {
          var u = vs[i].currentSrc || vs[i].src || '';
          if (u) hit(s, u, 'iframe');
        }
        var fs = doc.querySelectorAll('iframe');
        for (var j = 0; j < fs.length; j++) inspectFrame(s, fs[j], true);
      } catch (e) {}
    } else if (src && src.indexOf('http') === 0) {
      // 跨域播放器读不到内容：把地址交回 Dart，作为「打开该播放器继续嗅探」的入口
      if (!s.frames[src]) {
        s.frames[src] = 1;
        post({ t: 'iframe', id: s.id, url: src });
      }
    }
    noteOverlay(s, f, scoreOf(f, isNew));
  }

  function sweep(s) {
    if (!s || s.cancelled || s.stale) return;
    if (Date.now() - s.t0 > ATTR_MS) return;

    // 1. 新增 / 刚开始播放的 <video>
    var vids = [];
    try { vids = document.querySelectorAll('video'); } catch (e) {}
    for (var i = 0; i < vids.length; i++) {
      var v = vids[i];
      var isNew = !(s.pre && s.pre.has && s.pre.has(v));
      var playing = false;
      try { playing = !v.paused && v.currentTime > 0; } catch (e) {}
      // 点击前就存在、点击前也没在播的播放器与这次点击无关，
      // 否则页面上每个预加载了 src 的播放器都会被算进来
      var started = playing && !(s.prePlaying && s.prePlaying.has && s.prePlaying.has(v));
      if (!isNew && !started) continue;
      var src = '';
      try { src = v.currentSrc || v.src || ''; } catch (e) {}
      if (!src) {
        try {
          var ss = v.querySelectorAll('source');
          for (var k = 0; k < ss.length; k++) {
            if (ss[k].src) { src = ss[k].src; break; }
          }
        } catch (e) {}
      }
      if (src) hit(s, src, 'video');
      s.cand = v;
      noteOverlay(s, v, scoreOf(v, isNew));
    }

    // 2. iframe 播放器（同源读内容，跨域只报地址）
    var frames = [];
    try { frames = document.querySelectorAll('iframe'); } catch (e) {}
    for (var f = 0; f < frames.length; f++) {
      var frameNew = !(s.preFrames && s.preFrames.has && s.preFrames.has(frames[f]));
      inspectFrame(s, frames[f], frameNew);
    }

    // 3. performance 新增条目：兜住 Worker 内发起、或包装之前就发出的请求
    try {
      var entries = performance.getEntriesByType('resource');
      for (var e = s.perfBase; e < entries.length; e++) {
        hit(s, entries[e].name, 'perf');
      }
      if (entries.length > s.perfBase) s.perfBase = entries.length;
    } catch (e) {}

    // 4. 上一轮记录的候选容器可能还在展开动画里，重新评一次分
    try {
      if (s.cand && document.contains(s.cand) && s.score < 100) {
        noteOverlay(s, s.cand, scoreOf(s.cand, true));
      }
    } catch (e) {}
  }

  function begin(target) {
    var now = Date.now();
    while (sessions.length && now - sessions[0].t0 > ATTR_MS * 2) sessions.shift();
    if (sessions.length >= MAX_SESSIONS) {
      var old = sessions.shift();
      if (old && old.timers) {
        for (var i = 0; i < old.timers.length; i++) clearTimeout(old.timers[i]);
      }
    }

    var s = {
      id: ++seq,
      t0: now,
      label: labelOf(target),
      urls: {},
      order: [],
      frames: {},
      count: 0,
      score: 0,
      reported: 0,
      overlayTag: '',
      mse: 0,
      cand: null,
      cancelled: 0,
      stale: 0,
      pre: null,
      prePlaying: null,
      preFrames: null,
      perfBase: 0,
      timers: []
    };
    // 点击前的快照：新插入判定、以及「本来就在播」的排除都靠它
    try {
      s.pre = new WeakSet();
      s.prePlaying = new WeakSet();
      var vids = document.querySelectorAll('video');
      for (var i = 0; i < vids.length; i++) {
        s.pre.add(vids[i]);
        try {
          if (!vids[i].paused && vids[i].currentTime > 0) s.prePlaying.add(vids[i]);
        } catch (e) {}
      }
    } catch (e) { s.pre = null; s.prePlaying = null; }
    try {
      s.preFrames = new WeakSet();
      var fs0 = document.querySelectorAll('iframe');
      for (var m = 0; m < fs0.length; m++) s.preFrames.add(fs0[m]);
    } catch (e) { s.preFrames = null; }
    try { s.perfBase = performance.getEntriesByType('resource').length; } catch (e) {}

    // 新的点击接管观察权：旧会话不再扫描，媒体归给最新一次点击
    for (var k = 0; k < sessions.length; k++) sessions[k].stale = 1;
    sessions.push(s);

    var rect = target ? rectOf(target) : { x: 0, y: 0, w: 0, h: 0 };
    post({
      t: 'click', id: s.id, label: s.label,
      tag: target && target.tagName ? target.tagName.toLowerCase() : '',
      x: rect.x, y: rect.y
    });

    for (var j = 0; j < SWEEPS.length; j++) {
      (function (delay) {
        var timer = setTimeout(function () { sweep(s); }, delay);
        s.timers.push(timer);
      })(SWEEPS[j]);
    }
    return s;
  }

  function clearTimers() {
    for (var i = 0; i < sessions.length; i++) {
      var t = sessions[i].timers || [];
      for (var j = 0; j < t.length; j++) clearTimeout(t[j]);
      sessions[i].timers = [];
    }
  }

  // ---- 广告遮挡层 / 点击跳广告 的通用防护 ----
  //
  // 站点两种常见套路，都在「网页原生播放器」上：
  //  1. 播放器上盖一层全屏透明 div，点「播放」其实点在广告上，直接跳走；
  //  2. 播放按钮自己绑了 window.open，点了先弹一个广告窗口。
  //
  // 处理方式刻意保守：
  //  - 只把「fixed/absolute + z-index≥20 + 覆盖 ≥45% 视口 + 背景近乎透明 +
  //    里面没有 video/iframe」的层判为广告层（不透明的正常遮罩、真正的播放器容器都不动）；
  //  - 命中后只把这一层的 `pointer-events` 关掉，不删节点、不改样式外观
  //    ——下一次点击就能落到播放器上，页面看起来没有任何变化；
  //  - 点击后 1.5 秒内拒绝 window.open。正常人点链接开新窗口不会只隔一瞬，
  //    而广告弹窗几乎都发生在点击的同一帧。
  var shell = { tapAt: 0, popups: 0, layers: 0, blockClickUntil: 0 };
  window.__ssShell = shell;

  function alphaOf(c) {
    if (!c) return 1;
    var m = /rgba?\(([^)]+)\)/.exec(String(c));
    if (!m) return 1;
    var p = m[1].split(',');
    if (p.length < 4) return 1;
    var a = parseFloat(p[3]);
    return isNaN(a) ? 1 : a;
  }

  function bigEnough(el) {
    try {
      var r = el.getBoundingClientRect();
      var vw = window.innerWidth || 360;
      var vh = window.innerHeight || 640;
      if (r.width * r.height < vw * vh * 0.45) return false;
      // 必须是从视口左上角附近铺开的整屏层
      return r.left <= vw * 0.15 && r.top <= vh * 0.15;
    } catch (e) { return false; }
  }

  function looksLikeAdLayer(el) {
    try {
      if (!el || el.nodeType !== 1) return false;
      var tag = String(el.tagName || '').toUpperCase();
      if (tag === 'VIDEO' || tag === 'IFRAME' || tag === 'BODY' ||
          tag === 'HTML' || tag === 'CANVAS') return false;
      var st = getComputedStyle(el);
      if (st.pointerEvents === 'none') return false;
      if (st.position !== 'fixed' && st.position !== 'absolute') return false;
      var z = parseInt(st.zIndex, 10);
      if (isNaN(z) || z < 20) return false;
      if (!bigEnough(el)) return false;
      // 真正的播放器 / 弹窗容器不能动
      if (el.querySelector && el.querySelector('video,iframe,canvas')) return false;
      // 不透明的大色块通常是正常遮罩或背景，不碰
      if (alphaOf(st.backgroundColor) > 0.35) return false;
      // 有大量文字的层多半是真正的说明/弹窗，避免误伤
      var txt = String(el.innerText || '').trim();
      if (txt.length > 80) return false;
      return true;
    } catch (e) { return false; }
  }

  function killLayer(el) {
    try {
      el.style.setProperty('pointer-events', 'none', 'important');
      // 光关指针事件还不够：本次触摸的 click 目标在 pointerdown 时就锁定了，
      // 不拦一下的话「点广告层」这一下仍会触发它自己的跳转。
      shell.blockClickUntil = Date.now() + 800;
      shell.layers++;
      post({ t: 'shield', kind: 'layer', id: shell.layers,
             label: String(el.tagName || '').toLowerCase() });
    } catch (e) {}
  }

  /// 顺着点击目标往上找广告层；找不到再扫一遍 body 直接子节点
  function shieldAt(target) {
    var el = target, guard = 0;
    while (el && el !== document.body && guard++ < 6) {
      if (looksLikeAdLayer(el)) { killLayer(el); return true; }
      el = el.parentElement;
    }
    try {
      var kids = document.body.children;
      for (var i = 0; i < kids.length; i++) {
        if (looksLikeAdLayer(kids[i])) { killLayer(kids[i]); return true; }
      }
    } catch (e) {}
    return false;
  }

  // 手动清理：把当前页面上所有符合特征的遮挡层一次性关掉指针事件
  window.__ssClearLayers = function () {
    var n = 0;
    try {
      var kids = document.body.children;
      for (var i = 0; i < kids.length; i++) {
        if (looksLikeAdLayer(kids[i])) { killLayer(kids[i]); n++; }
      }
    } catch (e) {}
    post({ t: 'shield', kind: 'manual', id: n });
    return n;
  };

  // 点击后 1.5 秒内的 window.open 一律拒绝（广告弹窗几乎都发生在这一瞬）
  try {
    if (!window.__ssOpenWrapped) {
      window.__ssOpenWrapped = 1;
      var ssOpen = window.open;
      window.open = function () {
        if (Date.now() - shell.tapAt < 1500) {
          shell.popups++;
          post({ t: 'shield', kind: 'popup', id: shell.popups });
          return null;
        }
        return ssOpen.apply(window, arguments);
      };
    }
  } catch (e) {}

  // 刚清掉遮挡层的那一次点击：在 document 捕获阶段就掐掉，
  // 不让它冒泡到广告层自己的 click 处理器，也不让 <a> 默认跳转。
  // 只有真的识别到广告层时才会走到这里，普通点击完全不受影响。
  try {
    document.addEventListener('click', function (e) {
      if (!shell.blockClickUntil || Date.now() > shell.blockClickUntil) return;
      shell.blockClickUntil = 0;
      try {
        e.preventDefault();
        e.stopImmediatePropagation();
      } catch (err) {}
      // 单独一种 kind：这次只是「把已经算过的层再拦一下点击」，不重复计数
      post({ t: 'shield', kind: 'blocked', id: shell.layers, label: 'blocked-tap' });
    }, { capture: true });
  } catch (e) {}

  // 捕获阶段记录点击：pointerdown 比 click 早，能覆盖 mousedown 就换源的站点；
  // 其余监听全 passive，只有上面那条「刚清掉遮挡层」的一次性拦截会阻止默认行为。
  var lastDown = 0;
  var downX = 0, downY = 0;
  try {
    document.addEventListener('pointerdown', function (e) {
      lastDown = Date.now();
      shell.tapAt = lastDown;
      downX = e.clientX || 0;
      downY = e.clientY || 0;
      // 点在广告遮挡层上：先把这层的指针事件关掉，用户再点一次就落到播放器
      try { shieldAt(e.target); } catch (err) {}
      begin(e.target);
    }, { capture: true, passive: true });
  } catch (e) {}

  // 滑动翻页 / 拖拽不算点击：位移超过 12px 就作废这次会话，
  // 否则滚动时懒加载出来的视频会被算到「点击」头上
  try {
    document.addEventListener('pointerup', function (e) {
      var s = live();
      if (!s) return;
      var dx = (e.clientX || 0) - downX;
      var dy = (e.clientY || 0) - downY;
      if (dx * dx + dy * dy > 144) s.cancelled = 1;
    }, { capture: true, passive: true });
  } catch (e) {}

  try {
    document.addEventListener('pointercancel', function () {
      var s = live();
      if (s) s.cancelled = 1;
    }, { capture: true, passive: true });
  } catch (e) {}

  try {
    document.addEventListener('click', function (e) {
      // pointerdown 已经开过窗口就不再重复开，避免一次点击算两次
      if (Date.now() - lastDown < 1200) return;
      begin(e.target);
    }, { capture: true, passive: true });
  } catch (e) {}

  // 播放器起播：这是「点了才加载」的强信号
  try {
    var origPlay = HTMLMediaElement.prototype.play;
    if (origPlay) {
      HTMLMediaElement.prototype.play = function () {
        try {
          var s = live();
          if (s) {
            var u = this.currentSrc || this.src || '';
            if (u) hit(s, u, 'play');
            var isNew = !(s.pre && s.pre.has && s.pre.has(this));
            s.cand = this;
            noteOverlay(s, this, scoreOf(this, isNew));
          }
        } catch (e) {}
        return origPlay.apply(this, arguments);
      };
    }
  } catch (e) {}

  // 包装 fetch / XHR：只在归因窗口内旁路上报，不改变任何返回值
  try {
    var origFetch = window.fetch;
    if (origFetch) {
      window.fetch = function (input) {
        try {
          var s = live();
          if (s) {
            var u = (typeof input === 'string') ? input : (input && input.url);
            hit(s, u, 'fetch');
          }
        } catch (e) {}
        return origFetch.apply(this, arguments);
      };
    }
  } catch (e) {}

  try {
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      try {
        var s = live();
        if (s) hit(s, url, 'xhr');
      } catch (e) {}
      return origOpen.apply(this, arguments);
    };
  } catch (e) {}

  // MSE：blob 地址意味着真实地址被 MediaSource 吃掉，只能提示走回扫兜底
  try {
    var origCreate = URL.createObjectURL;
    if (origCreate) {
      URL.createObjectURL = function (obj) {
        try {
          var s = live();
          if (s && window.MediaSource && obj && obj instanceof window.MediaSource) {
            noteMse(s, 'mediasource');
          }
        } catch (e) {}
        return origCreate.apply(this, arguments);
      };
    }
  } catch (e) {}

  // 浮层通常是点击后动态插入的：MutationObserver 负责第一时间抓到
  try {
    if (window.MutationObserver) {
      var mo = new MutationObserver(function (records) {
        var s = live();
        if (!s) return;
        var budget = 40;
        for (var i = 0; i < records.length && budget > 0; i++) {
          var add = records[i].addedNodes;
          for (var j = 0; j < add.length && budget > 0; j++) {
            var n = add[j];
            if (!n || n.nodeType !== 1) continue;
            budget--;
            inspectNode(s, n);
          }
        }
      });
      var attach = function () {
        try {
          if (document.body) {
            mo.observe(document.body, { childList: true, subtree: true });
          }
        } catch (e) {}
      };
      if (document.body) attach();
      else document.addEventListener('DOMContentLoaded', attach);
    }
  } catch (e) {}

  // 手动嗅探 / 手动「捕获一次」时补扫
  window.__ssClickScan = function () {
    var s = live();
    if (s) sweep(s);
  };

  // 重置：清空会话与去重表，用于「重新开始捕获」
  window.__ssClickReset = function () {
    clearTimers();
    sessions = [];
    seen = {};
    seenCount = 0;
  };

  // 离开页面时收掉定时器，避免在已卸载的上下文里空转
  window.addEventListener('pagehide', clearTimers);
  window.addEventListener('beforeunload', clearTimers);
})();
''';

/// 清空点击会话与去重表，下一次点击从 1 重新计数。
const String kClickSniffResetJs = r'''
(function () {
  try { window.__ssClickReset && window.__ssClickReset(); } catch (e) {}
})();
''';

/// 手动嗅探时顺带跑一次点击会话的补扫（没有活跃会话时是空操作）。
const String kClickSniffScanJs = r'''
(function () {
  try { window.__ssClickScan && window.__ssClickScan(); } catch (e) {}
})();
''';
