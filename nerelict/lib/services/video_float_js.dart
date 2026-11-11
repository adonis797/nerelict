/// 网页侧「视频区域长按」浮标触发脚本。
///
/// 与 kSniffJs / kPlayerProbeJs 完全独立：不 Hook fetch/XHR、不改 DOM 属性、
/// 不做自动上报，只在用户长按（或长按菜单）网页里的 <video> 时通过
/// FloatChannel 上报一次当前视频地址，由 Flutter 侧显示「用 MA8N打开」浮标。
/// 因此不会改变原有自动嗅探、自动接管与资源聚合行为。
const String kVideoFloatJs = r'''
(function () {
  if (window.__ssFloatInjected) return;
  window.__ssFloatInjected = true;

  function absolute(u) {
    try { return new URL(u, location.href).href; } catch (e) { return u; }
  }

  function videoOf(node) {
    try {
      if (!node) return null;
      if (node.tagName === 'VIDEO') return node;
      if (node.closest) return node.closest('video');
      var p = node.parentElement;
      while (p) {
        if (p.tagName === 'VIDEO') return p;
        p = p.parentElement;
      }
    } catch (e) {}
    return null;
  }

  function report(v) {
    try {
      var s = v.currentSrc || v.src || '';
      if (!s) {
        var srcs = v.querySelectorAll('source');
        for (var i = 0; i < srcs.length; i++) {
          if (srcs[i].src) { s = srcs[i].src; break; }
        }
      }
      if (!s || s.indexOf('blob:') === 0 || s.indexOf('data:') === 0) return;
      var u = absolute(String(s));
      if (u.indexOf('http') !== 0) return;
      FloatChannel.postMessage(JSON.stringify({
        url: u,
        page: location.href,
        title: (document.title || '').slice(0, 120)
      }));
    } catch (e) {}
  }

  document.addEventListener('contextmenu', function (e) {
    var v = videoOf(e.target);
    if (v) report(v);
  }, true);

  var timer = null, sx = 0, sy = 0;
  document.addEventListener('touchstart', function (e) {
    var v = videoOf(e.target);
    if (!v || !e.touches || !e.touches.length) return;
    sx = e.touches[0].clientX;
    sy = e.touches[0].clientY;
    if (timer) clearTimeout(timer);
    timer = setTimeout(function () { timer = null; report(v); }, 700);
  }, true);

  document.addEventListener('touchmove', function (e) {
    if (!timer || !e.touches || !e.touches.length) return;
    if (Math.abs(e.touches[0].clientX - sx) > 12 ||
        Math.abs(e.touches[0].clientY - sy) > 12) {
      clearTimeout(timer);
      timer = null;
    }
  }, true);

  document.addEventListener('touchend', function () {
    if (timer) { clearTimeout(timer); timer = null; }
  }, true);
})();
''';
