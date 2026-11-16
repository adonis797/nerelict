// 点击归因脚本的行为验证（需要 Node，不进 Dart 回归链）。
// 用法：node tool/click_js_test.js
//
// 为什么要有它：登录入口的四个出口全在注入脚本里，纯文本断言只能证明
// 「代码里有这行」，证明不了「点了会怎样」。这里用一个极简 DOM 桩把脚本跑起来，
// 直接模拟 pointerdown / click，检查登录弹窗不被误杀、window.open 会被降级成同页跳转。
// 行为验证：在沙箱里跑点击归因脚本（click_sniff_js），检查
// 「登录弹窗不被误杀」「window.open 收窄并降级成同页跳转」两条改动。
const fs = require('fs');
const vm = require('vm');

const path = require('path');
const root = path.resolve(__dirname, '..');
const dart = fs.readFileSync(path.join(root, 'lib/services/click_sniff_js.dart'), 'utf8');
const start = dart.indexOf("r'''") + 4;
const end = dart.indexOf("'''", start);
if (start < 4 || end < 0) {
  console.error('抽取注入脚本失败：click_sniff_js.dart 里找不到 r\'\'\' 块');
  process.exit(1);
}
const code = dart.slice(start, end);
const posted = [];
const listeners = { document: {}, window: {} };
let navTo = null;

function addListener(store) {
  return function (type, fn) {
    (store[type] = store[type] || []).push({ fn, capture: true });
  };
}

function fire(store, type, event) {
  const list = (store[type] || []).slice();
  for (const l of list) {
    if (event.stopped) break;
    l.fn(event);
  }
}

// --- 极简 DOM ---
class El {
  constructor(tag, opts = {}) {
    this.tagName = tag.toUpperCase();
    this.nodeType = 1;
    this.children = [];
    this.parentElement = null;
    this.style = {
      _v: {},
      setProperty(k, v) { this._v[k] = v; },
      getPropertyValue(k) { return this._v[k] || ''; },
    };
    this._opts = opts;
    this._text = opts.text || '';
  }
  get innerText() { return this._text; }
  get className() { return this._opts.className || ''; }
  get id() { return this._opts.id || ''; }
  append(child) { child.parentElement = this; this.children.push(child); return child; }
  getBoundingClientRect() {
    return this._opts.rect || { left: 0, top: 0, width: 360, height: 640, right: 360, bottom: 640 };
  }
  querySelector(sel) {
    for (const c of this.children) {
      if (matchSel(c, sel)) return c;
      const deep = c.querySelector(sel);
      if (deep) return deep;
    }
    return null;
  }
  querySelectorAll(sel) {
    const out = [];
    for (const c of this.children) {
      if (matchSel(c, sel)) out.push(c);
      out.push(...c.querySelectorAll(sel));
    }
    return out;
  }
  closest(sel) {
    let el = this;
    while (el) {
      if (matchSel(el, sel)) return el;
      el = el.parentElement;
    }
    return null;
  }
  getAttribute(name) {
    if (name === 'href') return this._opts.href || null;
    if (name === 'target') return this._opts.target || null;
    return this._opts.attrs ? this._opts.attrs[name] : null;
  }
  setAttribute() {}
}

function matchSel(el, sel) {
  const parts = String(sel).split(',').map((s) => s.trim().toLowerCase());
  for (const p of parts) {
    if (!p) continue;
    if (p === 'video' || p === 'audio' || p === 'input' || p === 'form' ||
        p === 'select' || p === 'textarea' || p === 'dialog') {
      if (el.tagName === p.toUpperCase()) return true;
      continue;
    }
    if (p === '[role="dialog"]' && el._opts.role === 'dialog') return true;
    if (p === '[role="alertdialog"]' && el._opts.role === 'alertdialog') return true;
    if (p === '[aria-modal="true"]' && el._opts.ariaModal === 'true') return true;
    if (p.startsWith('a[target]') && el.tagName === 'A' && el._opts.target) return true;
  }
  return false;
}

const styleOf = new Map();
function setStyle(el, st) { styleOf.set(el, st); }

const body = new El('body');
const windowObj = {};

const doc = {
  title: 'test',
  body,
  documentElement: body,
  contains: () => true,
  addEventListener: addListener(listeners.document),
  createElement: (t) => new El(t),
  querySelector: (s) => body.querySelector(s),
  querySelectorAll: (s) => body.querySelectorAll(s),
};

class HTMLMediaElement {
  constructor() { this.paused = true; this.ended = false; this.currentTime = 0; this.src = ''; }
}
HTMLMediaElement.prototype.play = function () { this.paused = false; return Promise.resolve(); };

class XMLHttpRequest {
  open() {}
  send() {}
  setRequestHeader() {}
  addEventListener() {}
}

const sandbox = {
  document: doc,
  location: { href: 'https://site.com/watch', get pathname() { return '/watch'; } },
  performance: { getEntriesByType: () => [] },
  ClickChannel: { postMessage: (s) => posted.push(JSON.parse(s)) },
  MutationObserver: class { observe() {} disconnect() {} },
  MediaSource: function () {},
  getComputedStyle: (el) => {
    const base = styleOf.get(el) || { pointerEvents: 'auto', position: 'static', zIndex: 'auto', backgroundColor: 'rgba(0, 0, 0, 0)' };
    // 内联样式优先级最高：killLayer 写 pointer-events:none 之后，计算样式要跟着变
    const inline = (el && el.style && el.style._v) || {};
    const merged = Object.assign({}, base);
    if (inline['pointer-events']) merged.pointerEvents = inline['pointer-events'];
    return merged;
  },
  setTimeout: (fn) => { try { fn(); } catch (e) {} return 0; },
  clearTimeout: () => {},
  setInterval: () => 0,
  clearInterval: () => {},
  console,
  URL,
  JSON,
  String,
  Number,
  Object,
  Array,
  RegExp,
  Math,
  Date,
  isNaN,
  parseInt,
  parseFloat,
  Promise,
  XMLHttpRequest,
  HTMLMediaElement,
};
sandbox.window = sandbox;
sandbox.window.innerWidth = 360;
sandbox.window.innerHeight = 640;
sandbox.window.addEventListener = addListener(listeners.window);
sandbox.window.open = function () { throw new Error('原生 window.open 不该被调到'); };
vm.createContext(sandbox);
vm.runInContext(code, sandbox);

const results = [];
function check(ok, label, detail) {
  results.push({ ok, label });
  console.log(`${ok ? '  ✓' : '  ✗'} ${label}${!ok && detail ? ' → ' + detail : ''}`);
}

function tapOn(el) {
  fire(listeners.document, 'pointerdown', {
    target: el, clientX: 10, clientY: 10, preventDefault() {},
  });
}
function clickOn(el, extra = {}) {
  const ev = Object.assign({
    target: el, preventDefault() { this.defaultPrevented = true; },
    stopImmediatePropagation() { this.stopped = true; },
  }, extra);
  fire(listeners.document, 'click', ev);
  return ev;
}

// ---- 1. 登录弹窗不该被误判成广告遮挡层 ----
// 结构：透明外壳（fixed / z=999 / inset:0）> 遮罩 > 表单 > 登录按钮
const shellEl = new El('div', { rect: { left: 0, top: 0, width: 360, height: 640, right: 360, bottom: 640 } });
setStyle(shellEl, {
  pointerEvents: 'auto', position: 'fixed', zIndex: '999', backgroundColor: 'rgba(0, 0, 0, 0)',
});
const maskEl = shellEl.append(new El('div', { rect: { left: 0, top: 0, width: 360, height: 640 } }));
setStyle(maskEl, {
  pointerEvents: 'auto', position: 'absolute', zIndex: '998', backgroundColor: 'rgba(0, 0, 0, 0.3)',
});
const formEl = maskEl.append(new El('form', { rect: { left: 20, top: 200, width: 320, height: 240 } }));
formEl._text = '登录 账号 密码 记住我';
const loginInput = formEl.append(new El('input', { rect: { left: 40, top: 240, width: 280, height: 40 } }));
const loginBtn = formEl.append(new El('button', { rect: { left: 40, top: 380, width: 280, height: 44 }, text: '登录' }));
body.append(shellEl);

tapOn(loginBtn);
check(shellEl.style.getPropertyValue('pointer-events') === '', '含表单控件的登录外壳不被关掉指针事件',
  shellEl.style.getPropertyValue('pointer-events'));
check(maskEl.style.getPropertyValue('pointer-events') === '', '半透明遮罩层也不被误杀');
const blockedAfterLogin = posted.some((p) => p.t === 'shield' && p.kind === 'layer');
check(!blockedAfterLogin, '点登录按钮不上报「已移除遮挡层」');

// ---- 2. 真正的透明广告遮挡层仍然要被清掉 ----
const adLayer = new El('div', { rect: { left: 0, top: 0, width: 360, height: 640 }, text: '' });
setStyle(adLayer, {
  pointerEvents: 'auto', position: 'fixed', zIndex: '500', backgroundColor: 'rgba(0, 0, 0, 0)',
});
body.append(adLayer);
tapOn(adLayer);
check(adLayer.style.getPropertyValue('pointer-events') === 'none', '无表单控件的透明遮挡层照样被关掉',
  adLayer.style.getPropertyValue('pointer-events'));
check(posted.some((p) => p.t === 'shield' && p.kind === 'layer'), '诚实上报一次遮挡层清理');

// ---- 3. 点登录按钮里的 window.open：不再被当成广告弹窗 ----
// 上一步清广告层会留下 800ms 的「拦当次点击」窗口，这里先复位，只测 window.open 本身
sandbox.window.__ssShell.blockClickUntil = 0;
const childBtn = formEl.append(new El('button', { rect: { left: 40, top: 430, width: 120, height: 40 } }));
tapOn(childBtn);
const beforePopups = posted.filter((p) => p.t === 'shield' && p.kind === 'popup').length;
sandbox.location.href = 'https://site.com/watch';
const ret = sandbox.window.open('https://passport.site.com/login?from=watch');
check(ret !== null, 'window.open 不再返回 null（站点不会走「弹窗被拦截」分支）');
check(sandbox.location.href === 'https://passport.site.com/login?from=watch',
  'window.open 降级成同页跳转', sandbox.location.href);
check(posted.filter((p) => p.t === 'shield' && p.kind === 'popup').length === beforePopups,
  '这次没有被记成广告弹窗');

// ---- 4. 点视频容器里的 window.open：仍然要拦 ----
const player = body.append(new El('div', { rect: { left: 0, top: 100, width: 360, height: 200 } }));
const video = player.append(new El('video', { rect: { left: 0, top: 100, width: 360, height: 200 } }));
tapOn(video);
const popupRet = sandbox.window.open('https://ad.example.com/landing');
check(popupRet === null, '点在视频容器上的 window.open 仍然被拦下');
check(posted.some((p) => p.t === 'shield' && p.kind === 'popup'), '并上报一次广告弹窗');

// ---- 5. <a target="_blank"> 改成同页跳转 ----
const link = formEl.append(new El('a', { href: '/login/oauth', target: '_blank' }));
sandbox.location.href = 'https://site.com/watch';
const ev = clickOn(link);
check(ev.defaultPrevented === true, 'target=_blank 的链接被接管（阻止默认）');
check(sandbox.location.href === 'https://site.com/login/oauth', '并改成同页跳转', sandbox.location.href);

// ---- 6. 深链不接管，留给 Dart 侧 ----
const deepLink = formEl.append(new El('a', { href: 'weixin://dl/business', target: '_blank' }));
sandbox.location.href = 'https://site.com/watch';
clickOn(deepLink);
check(sandbox.location.href === 'https://site.com/watch', '非 http(s) 深链不被脚本劫持');

const failed = results.filter((r) => !r.ok).length;
console.log(failed === 0 ? `\n点击脚本行为全部通过：${results.length} 项` : `\n失败 ${failed} 项`);
process.exit(failed === 0 ? 0 : 1);
