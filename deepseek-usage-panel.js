// ==UserScript==
// @name         DeepSeek 消耗
// @description  在 Codex 顶部菜单栏加一个「消耗」按钮，显示 DeepSeek 充值余额与今日消费
// @version      1.0.12
// @match        app://-/*
// @grant        none
// ==/UserScript==

(function () {
  'use strict';

  var VERSION = '1.0.12';
  if (window.__dsUsageUIVersion === VERSION) return;
  window.__dsUsageUIVersion = VERSION;

  var legacyButton = document.getElementById('ds-usage-menu-trigger');
  if (legacyButton && legacyButton.parentNode) legacyButton.parentNode.removeChild(legacyButton);
  var legacyPanel = document.getElementById('ds-usage-panel');
  if (legacyPanel && legacyPanel.parentNode) legacyPanel.parentNode.removeChild(legacyPanel);

  var BTN_ID = 'ds-usage-menu-trigger';
  var PANEL_ID = 'ds-usage-panel';
  var STATE = { open: false, panel: null, btn: null, hintTimer: null };
  var DATA = window.__DSUsage || null;
  var TEXT_PRIMARY = 'var(--color-token-text-primary, #1a1c1f)';
  var TEXT_SECONDARY = 'color-mix(in oklab, var(--color-token-text-primary, #1a1c1f) 75%, transparent)';

  function money(value, symbol) {
    if (value === null || value === undefined || value === '') return '—';
    var n = Number(value);
    if (!isFinite(n)) return String(value);
    return (symbol || '') + n.toFixed(2);
  }

  function timeText(ts) {
    if (!ts) return '—';
    var d = new Date(ts);
    function p(x) { return (x < 10 ? '0' : '') + x; }
    return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }

  function row(label, value, extraClass) {
    var wrap = document.createElement('div');
    wrap.style.cssText = 'display:flex;align-items:baseline;justify-content:space-between;gap:16px;min-height:28px;box-sizing:border-box;margin:0 4px;padding:5px 16px;';

    var l = document.createElement('span');
    l.textContent = label;
    l.style.cssText = 'color:' + TEXT_PRIMARY + ';flex:0 0 auto;font-family:inherit;font-size:12px;font-weight:400;line-height:18px;';

    var v = document.createElement('span');
    v.textContent = value;
    v.style.cssText = 'font-variant-numeric:tabular-nums;text-align:right;font-family:inherit;font-size:12px;font-weight:400;line-height:18px;' + (extraClass || '');

    wrap.append(l, v);
    return wrap;
  }

  function buildPanel() {
    var panel = document.createElement('div');
    panel.id = PANEL_ID;
    panel.style.cssText = [
      'position:fixed',
      'z-index:2147483000',
      'width:220px',
      'min-width:220px',
      'box-sizing:border-box',
      'padding:4px 0',
      'border:0',
      'border-radius:7.5px',
      'background:var(--color-codex-application-menu, #f8f8f9)',
      'color:var(--color-token-text-primary, #1a1c1f)',
      'box-shadow:0 4px 12px rgba(0,0,0,.42)',
      'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
      'font-size:12px',
      'font-weight:400',
      'line-height:18px',
      'user-select:none'
    ].join(';');

    var title = document.createElement('div');
    title.textContent = 'DeepSeek 消耗';
    title.style.cssText = 'font-size:12px;font-weight:600;line-height:18px;margin:0 4px;padding:5px 16px;';

    var body = document.createElement('div');
    body.dataset.dsPart = 'body';

    var footer = document.createElement('div');
    footer.dataset.dsPart = 'footer';
    footer.style.cssText = [
      'display:flex',
      'align-items:center',
      'justify-content:space-between',
      'gap:10px',
      'min-height:31px',
      'box-sizing:border-box',
      'margin:4px 4px 0',
      'padding:7px 12px 3px',
      'border-top:1px solid var(--color-token-border, rgba(0,0,0,.08))'
    ].join(';');

    var stamp = document.createElement('span');
    stamp.dataset.dsPart = 'stamp';
    stamp.style.cssText = 'color:' + TEXT_SECONDARY + ';font-family:inherit;font-size:12px;font-weight:400;line-height:18px;';

    var refresh = document.createElement('button');
    refresh.type = 'button';
    refresh.dataset.dsPart = 'refresh';
    refresh.textContent = '刷新';
    refresh.style.cssText = [
      'cursor:pointer',
      'border:0',
      'background:transparent',
      'color:var(--color-token-text-primary, #1a1c1f)',
      'border-radius:7.5px',
      'min-height:24px',
      'margin:-3px -4px',
      'padding:3px 8px',
      'font-family:inherit',
      'font-size:12px',
      'font-weight:400',
      'line-height:18px',
      'transition:background-color .1s ease'
    ].join(';');
    function setRefreshHover(active) {
      refresh.style.background = active ? 'color-mix(in srgb, var(--color-token-text-primary, #1a1c1f) 7%, transparent)' : 'transparent';
    }
    refresh.addEventListener('mouseenter', function () { setRefreshHover(true); });
    refresh.addEventListener('mouseleave', function () { setRefreshHover(false); });
    refresh.addEventListener('focus', function () { setRefreshHover(true); });
    refresh.addEventListener('blur', function () { setRefreshHover(false); });
    refresh.addEventListener('click', function (event) {
      event.preventDefault();
      event.stopPropagation();
      requestRefresh();
    });

    footer.append(stamp, refresh);
    panel.append(title, body, footer);
    return panel;
  }

  function render() {
    if (!STATE.panel) return;
    var body = STATE.panel.querySelector('[data-ds-part=body]');
    var stamp = STATE.panel.querySelector('[data-ds-part=stamp]');
    if (!body || !stamp) return;

    body.textContent = '';
    var data = DATA;

    if (!data) {
      body.textContent = '等待助手进程…';
      body.style.color = TEXT_SECONDARY;
      stamp.textContent = '';
      return;
    }

    body.style.color = '';

    if (data.error && !data.ok) {
      body.textContent = '获取失败：' + data.error;
      body.style.color = TEXT_SECONDARY;
      stamp.textContent = timeText(data.updatedAt);
      return;
    }

    var symbol = data.symbol || '';
    var rows = [];

    if (data.toppedUpBalance !== null && data.toppedUpBalance !== undefined) {
      rows.push(row('充值余额', money(data.toppedUpBalance, symbol)));
    }
    rows.push(row('今日消费', money(data.todaySpend, symbol)));

    rows.forEach(function (r) { body.append(r); });

    if (data.todaySpend === null || data.todaySpend === undefined) {
      var note = document.createElement('div');
      note.textContent = data.todaySpendUnavailable || '精确值暂不可用';
      note.style.cssText = 'color:' + TEXT_SECONDARY + ';margin:0 4px;padding:2px 16px 4px;font-size:11px;line-height:16px;';
      body.append(note);
    }

    stamp.textContent = data.updatedAt ? '同步于 ' + timeText(data.updatedAt) : '未同步';
  }

  function positionPanel() {
    if (!STATE.btn || !STATE.panel) return;
    var rect = STATE.btn.getBoundingClientRect();
    var width = STATE.panel.offsetWidth || 220;
    var left = Math.min(rect.left, Math.max(8, window.innerWidth - width - 8));
    STATE.panel.style.left = Math.round(left) + 'px';
    STATE.panel.style.top = Math.round(rect.bottom + 6) + 'px';
  }

  function closePanel() {
    if (STATE.panel && STATE.panel.parentNode) STATE.panel.parentNode.removeChild(STATE.panel);
    STATE.panel = null;
    STATE.open = false;
    setButtonState(false);
    document.removeEventListener('mousedown', onDocMouseDown, true);
    window.removeEventListener('resize', positionPanel, true);
  }

  function onDocMouseDown(event) {
    if (!STATE.panel) return;
    if (STATE.panel.contains(event.target)) return;
    if (STATE.btn && STATE.btn.contains(event.target)) return;
    closePanel();
  }

  function setButtonState(open) {
    if (!STATE.btn) return;
    STATE.btn.setAttribute('aria-expanded', open ? 'true' : 'false');
    STATE.btn.setAttribute('data-state', open ? 'open' : 'closed');
  }

  function menubarItem(node) {
    var element = node && node.nodeType === 1 ? node : node && node.parentElement;
    if (!element || !element.closest) return null;
    var item = element.closest('button[role=menuitem]');
    return item && item.closest('[role=menubar]') ? item : null;
  }

  function reactProps(node) {
    if (!node) return null;
    var key = Object.keys(node).find(function (name) {
      return name.indexOf('__reactProps$') === 0;
    });
    return key ? node[key] : null;
  }

  function openMenuItem(item) {
    if (!item) return false;
    var props = reactProps(item);
    if (!props || typeof props.onPointerDown !== 'function') return false;
    props.onPointerDown({
      defaultPrevented: false,
      currentTarget: item,
      target: item,
      button: 0,
      buttons: 1,
      ctrlKey: false,
      metaKey: false,
      shiftKey: false,
      altKey: false,
      pointerType: 'mouse',
      isPrimary: true,
      preventDefault: function () { this.defaultPrevented = true; },
      stopPropagation: function () {}
    });
    return true;
  }

  function openNativeItem() {
    return Array.from(document.querySelectorAll('[role=menubar] button[role=menuitem][aria-expanded=true]'))
      .find(function (item) { return item !== STATE.btn; }) || null;
  }

  function closeNativeMenus() {
    var item = openNativeItem();
    return item ? openMenuItem(item) : false;
  }

  function onMenuPointerOver(event) {
    var item = menubarItem(event.target);
    if (!item) return;

    if (item === STATE.btn) {
      if (STATE.open || !openNativeItem()) return;
      closeNativeMenus();
      openPanel();
      return;
    }

    if (!STATE.open) return;
    closePanel();
    openMenuItem(item);
  }

  function closeForOtherMenu(event) {
    if (!STATE.open) return;
    var item = menubarItem(event.target);
    if (!item || item === STATE.btn) return;
    closePanel();
  }

  var MENU_GUARD = window.__dsUsageMenuGuard;
  if (!MENU_GUARD) {
    MENU_GUARD = { pointerOver: null, close: null };
    window.__dsUsageMenuGuard = MENU_GUARD;
    var runMenuPointerOver = function (event) {
      if (MENU_GUARD.pointerOver) MENU_GUARD.pointerOver(event);
    };
    var runMenuGuard = function (event) {
      if (MENU_GUARD.close) MENU_GUARD.close(event);
    };
    document.addEventListener('pointerover', runMenuPointerOver, true);
    document.addEventListener('focusin', runMenuGuard, true);
    document.addEventListener('click', runMenuGuard, true);
  }
  MENU_GUARD.pointerOver = onMenuPointerOver;
  MENU_GUARD.close = closeForOtherMenu;

  function openPanel() {
    if (STATE.open) return;
    STATE.panel = buildPanel();
    document.body.append(STATE.panel);
    STATE.open = true;
    setButtonState(true);
    positionPanel();
    render();
    document.addEventListener('mousedown', onDocMouseDown, true);
    window.addEventListener('resize', positionPanel, true);
    requestRefresh();
  }

  function togglePanel() {
    if (STATE.open) closePanel(); else openPanel();
  }

  function requestRefresh() {
    try { window.__dsUsageRefreshFlag = true; } catch (error) {}
    var btn = STATE.btn;
    if (btn) {
      btn.dataset.dsBusy = '1';
      window.setTimeout(function () { if (btn) btn.dataset.dsBusy = ''; }, 1500);
    }
  }

  function ensureButton() {
    var bar = document.querySelector('[role=menubar]');
    if (!bar) return;
    var existing = bar.querySelector('#' + BTN_ID);
    if (existing) {
      if (existing.getAttribute('data-ds-usage-version') === VERSION) {
        STATE.btn = existing;
        return;
      }
      existing.parentNode.removeChild(existing);
    }

    var siblings = bar.querySelectorAll('button[role=menuitem]');
    var template = siblings.length ? siblings[0] : null;
    var anchor = bar.querySelector('#application-menu-content-anchor');

    var btn = document.createElement('button');
    btn.type = 'button';
    btn.id = BTN_ID;
    btn.setAttribute('data-ds-usage-version', VERSION);
    btn.setAttribute('role', 'menuitem');
    btn.setAttribute('aria-haspopup', 'menu');
    btn.setAttribute('aria-expanded', 'false');
    btn.setAttribute('data-state', 'closed');
    btn.setAttribute('aria-label', '消耗');
    btn.textContent = '消耗';
    if (template && template.className) btn.className = template.className;
    else btn.style.cssText = 'padding:2px 10px;border-radius:10px;border:1px solid transparent;background:transparent;cursor:pointer;';

    btn.addEventListener('click', function (event) {
      event.preventDefault();
      event.stopPropagation();
      closeNativeMenus();
      togglePanel();
    });

    if (anchor && anchor.parentNode === bar) bar.insertBefore(btn, anchor);
    else bar.append(btn);

    STATE.btn = btn;
  }

  function apply(data) {
    DATA = data;
    window.__DSUsage = data;
    if (STATE.open) render();
  }
  window.__dsUsageApply = apply;

  window.addEventListener('message', function (event) {
    var message = event && event.data;
    if (message && message.type === 'ds-usage-data') apply(message.payload);
  }, true);

  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape' && STATE.open) closePanel();
  }, true);

  var observer = new MutationObserver(function () { ensureButton(); });
  function boot() {
    ensureButton();
    if (!STATE.btn) window.setTimeout(boot, 800);
    if (document.body) observer.observe(document.body, { childList: true, subtree: true });
  }
  boot();
})();



