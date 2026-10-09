/*
 * el_printer - Empire Line printer dashboard.
 * Every action is sent to the Lua client (which forwards it to the server) and the UI only
 * reflects confirmed server responses. No success state is shown before the server answers.
 */
(function () {
  'use strict';

  const RESOURCE = typeof window.GetParentResourceName === 'function' ? window.GetParentResourceName() : 'el_printer';
  const $ = (id) => document.getElementById(id);

  const STATUS = {
    ready: { label: 'Ready', tone: 'ok' },
    busy: { label: 'Printing', tone: 'busy' },
    no_paper: { label: 'Out of Paper', tone: 'bad' },
    no_ink: { label: 'Out of Ink', tone: 'bad' },
    maintenance: { label: 'Maintenance Mode', tone: 'warn' },
    broken: { label: 'Requires Maintenance', tone: 'bad' },
    repairing: { label: 'Repairing', tone: 'warn' },
    offline: { label: 'Offline', tone: 'bad' },
  };

  const STATUS_ALERTS = {
    no_paper: { text: 'Out of paper. Load paper to continue printing.', icon: 'fa-file-circle-exclamation', tone: 'bad' },
    no_ink: { text: 'Out of ink. Load ink to continue printing.', icon: 'fa-droplet-slash', tone: 'bad' },
    maintenance: { text: 'Maintenance mode is active. Printing is paused.', icon: 'fa-screwdriver-wrench', tone: 'warn' },
    broken: { text: 'Printer requires maintenance before it can print again.', icon: 'fa-triangle-exclamation', tone: 'bad' },
    repairing: { text: 'Repair in progress. The printer will be available shortly.', icon: 'fa-gears', tone: 'warn' },
    offline: { text: 'This printer is offline.', icon: 'fa-power-off', tone: 'bad' },
  };

  const state = {
    settings: { sounds: true, volume: 0.25, notifyDuration: 4500 },
    open: null,
    dash: null,
    printer: null,
    tab: 'create',
    category: 'All',
    template: null,
    values: {},
    errors: {},
    copies: 1,
    previewModel: null,
    previewDirty: false,
    selectedDocId: null,
    docDetail: null,
    docLoading: false,
    docCopies: 1,
    filter: { q: '', type: 'all' },
    viewer: null,
    progress: null,
  };

  /* ================================================================ helpers */

  function h(tag, attrs, children) {
    const node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (key) {
        const value = attrs[key];
        if (value === undefined || value === null || value === false) return;
        if (key === 'class') node.className = value;
        else if (key === 'text') node.textContent = String(value);
        else if (key === 'style') node.setAttribute('style', value);
        else if (key.indexOf('on') === 0) node.addEventListener(key.slice(2).toLowerCase(), value);
        else if (value === true) node.setAttribute(key, '');
        else node.setAttribute(key, String(value));
      });
    }
    (children || []).forEach(function (child) {
      if (child === null || child === undefined || child === false) return;
      node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
    });
    return node;
  }

  function fa(name, extra) {
    return h('i', { class: (name.indexOf('fa-regular') === 0 ? '' : 'fa-solid ') + name + (extra ? ' ' + extra : ''), 'aria-hidden': 'true' });
  }

  function btn(opts) {
    const children = [];
    if (opts.icon) children.push(fa(opts.icon));
    if (opts.label) children.push(h('span', { text: opts.label }));
    const node = h('button', {
      class: 'el-btn ' + (opts.variant || 'el-btn-secondary') + (opts.size ? ' ' + opts.size : '') + (opts.className ? ' ' + opts.className : ''),
    }, children);
    setDisabled(node, opts.disabled, opts.tip);
    if (opts.onClick) {
      node.addEventListener('click', function () {
        if (!isDisabled(node)) opts.onClick(node);
      });
    }
    return node;
  }

  function money(amount) {
    if (!amount || amount <= 0) return 'Free';
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(amount);
  }

  function plural(count, word) {
    return count + ' ' + word + (count === 1 ? '' : 's');
  }

  function copiesLabel(count) {
    return count + (count === 1 ? ' copy' : ' copies');
  }

  // Disabled buttons keep receiving hover events so their tooltip can explain why.
  function setDisabled(node, disabled, reason) {
    node.classList.toggle('el-is-disabled', !!disabled);
    node.setAttribute('aria-disabled', disabled ? 'true' : 'false');
    node.setAttribute('data-tip', disabled && reason ? reason : (node.getAttribute('data-base-tip') || ''));
  }

  function isDisabled(node) {
    return node.classList.contains('el-is-disabled');
  }

  function seconds(ms) {
    const s = Math.max(0, Math.ceil(ms / 1000));
    return s >= 60 ? Math.floor(s / 60) + 'm ' + (s % 60) + 's' : s + 's';
  }

  function post(name, data) {
    return fetch('https://' + RESOURCE + '/' + name, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data || {}),
    }).then(function (res) { return res.json(); });
  }

  function request(action, payload) {
    return post('el_request', { action: action, payload: payload || {} })
      .then(function (res) { return res || { ok: false, message: 'Unexpected Error - Nothing Was Changed' }; })
      .catch(function () { return { ok: false, error: 'timeout', message: 'The Server Did Not Respond' }; });
  }

  // Runs an async action with a loading state on the button. Prevents double submission.
  function withLoading(button, fn) {
    if (button && button.classList.contains('el-loading')) return Promise.resolve(null);
    if (button) { button.classList.add('el-loading'); button.disabled = true; }
    return Promise.resolve()
      .then(fn)
      .finally(function () {
        if (button) { button.classList.remove('el-loading'); button.disabled = false; }
      });
  }

  /* ================================================================ toasts */

  const TOAST = {
    success: { title: 'Success', icon: 'fa-circle-check' },
    error: { title: 'Error', icon: 'fa-circle-exclamation' },
    warning: { title: 'Warning', icon: 'fa-triangle-exclamation' },
    info: { title: 'Printer', icon: 'fa-print' },
  };

  function toast(message, type, duration) {
    const kind = TOAST[type] ? type : 'info';
    const life = duration || state.settings.notifyDuration || 4500;
    const container = $('el-toasts');
    while (container.children.length >= 4) container.firstChild.remove();
    const bar = h('div', { class: 'el-toast-bar' });
    bar.style.animationDuration = life + 'ms';
    const node = h('div', { class: 'el-toast', 'data-type': kind }, [
      h('div', { class: 'el-toast-icon' }, [fa(TOAST[kind].icon)]),
      h('div', { class: 'el-toast-text' }, [
        h('div', { class: 'el-toast-title', text: TOAST[kind].title }),
        h('div', { class: 'el-toast-message', text: message }),
      ]),
      bar,
    ]);
    container.appendChild(node);
    setTimeout(function () {
      node.classList.add('el-leaving');
      setTimeout(function () { node.remove(); }, 260);
    }, life);
  }

  /* ================================================================ tooltip */

  const tooltip = $('el-tooltip');
  let tipTarget = null;

  document.addEventListener('mouseover', function (event) {
    const target = event.target.closest('[data-tip]');
    if (!target || !target.getAttribute('data-tip')) {
      if (tipTarget) { tooltip.classList.remove('el-visible'); tipTarget = null; }
      return;
    }
    if (target === tipTarget) return;
    tipTarget = target;
    tooltip.textContent = target.getAttribute('data-tip');
    const rect = target.getBoundingClientRect();
    tooltip.style.left = '0px';
    tooltip.style.top = '0px';
    tooltip.classList.add('el-visible');
    const tipRect = tooltip.getBoundingClientRect();
    let left = rect.left + rect.width / 2 - tipRect.width / 2;
    left = Math.max(8, Math.min(window.innerWidth - tipRect.width - 8, left));
    let top = rect.top - tipRect.height - 8;
    if (top < 8) top = rect.bottom + 8;
    tooltip.style.left = left + 'px';
    tooltip.style.top = top + 'px';
  });

  function hideTooltip() {
    tooltip.classList.remove('el-visible');
    tipTarget = null;
  }

  /* ================================================================ modal */

  let modalResolve = null;

  function confirmDialog(opts) {
    const modal = $('el-modal');
    $('el-modal-title').textContent = opts.title;
    $('el-modal-text').textContent = opts.text || '';
    $('el-modal-icon').className = 'fa-solid ' + (opts.icon || 'fa-circle-question');
    modal.querySelector('.el-modal').setAttribute('data-tone', opts.tone || 'default');
    const confirm = $('el-modal-confirm');
    confirm.className = 'el-btn ' + (opts.tone === 'danger' ? 'el-btn-danger' : 'el-btn-primary');
    confirm.querySelector('span').textContent = opts.confirmLabel || 'Confirm';
    modal.classList.add('el-visible');
    hideTooltip();
    return new Promise(function (resolve) { modalResolve = resolve; });
  }

  function closeModal(result) {
    $('el-modal').classList.remove('el-visible');
    if (modalResolve) { const resolve = modalResolve; modalResolve = null; resolve(result); }
  }

  $('el-modal-cancel').addEventListener('click', function () { closeModal(false); });
  $('el-modal-confirm').addEventListener('click', function () { closeModal(true); });
  $('el-modal').addEventListener('mousedown', function (event) { if (event.target === $('el-modal')) closeModal(false); });

  /* ================================================================ dropdown */

  const openSelects = new Set();

  function closeSelects(except) {
    openSelects.forEach(function (api) { if (api !== except) api.close(); });
  }

  function createSelect(container, opts) {
    container.textContent = '';
    container.classList.add('el-select');
    let value = opts.value;
    let focusIndex = -1;
    const label = h('span');
    const trigger = h('button', { class: 'el-select-trigger', type: 'button' }, [label, fa('fa-chevron-down')]);
    const menu = h('div', { class: 'el-select-menu', role: 'listbox' });
    container.appendChild(trigger);
    container.appendChild(menu);

    const api = {
      open: function () {
        closeSelects(api);
        container.classList.add('el-open');
        openSelects.add(api);
        focusIndex = opts.options.findIndex(function (o) { return o.value === value; });
        paint();
      },
      close: function () {
        container.classList.remove('el-open');
        openSelects.delete(api);
      },
      isOpen: function () { return container.classList.contains('el-open'); },
      key: function (event) {
        if (event.key === 'ArrowDown') { focusIndex = Math.min(opts.options.length - 1, focusIndex + 1); paint(); return true; }
        if (event.key === 'ArrowUp') { focusIndex = Math.max(0, focusIndex - 1); paint(); return true; }
        if (event.key === 'Enter' && focusIndex >= 0) { choose(opts.options[focusIndex].value); return true; }
        return false;
      },
    };

    function choose(next) {
      value = next;
      api.close();
      paint();
      if (opts.onChange) opts.onChange(value);
    }

    function paint() {
      const selected = opts.options.find(function (o) { return o.value === value; });
      label.textContent = selected ? selected.label : (opts.placeholder || 'Select an option');
      label.className = selected ? '' : 'el-placeholder';
      menu.textContent = '';
      opts.options.forEach(function (option, index) {
        menu.appendChild(h('button', {
          type: 'button',
          class: 'el-select-option' + (option.value === value ? ' el-selected' : '') + (index === focusIndex ? ' el-focus' : ''),
          role: 'option',
          onClick: function () { choose(option.value); },
        }, [h('span', { text: option.label })]));
      });
    }

    trigger.addEventListener('click', function () { api.isOpen() ? api.close() : api.open(); });
    container.__elSelect = api;
    paint();
    return api;
  }

  document.addEventListener('mousedown', function (event) {
    if (!event.target.closest('.el-select')) closeSelects();
  });

  /* ================================================================ sound */

  const PrinterSound = (function () {
    let ctx = null;
    let nodes = null;

    function start() {
      if (!state.settings.sounds || nodes) return;
      try {
        ctx = ctx || new (window.AudioContext || window.webkitAudioContext)();
        if (ctx.state === 'suspended') ctx.resume();
        const volume = Math.max(0, Math.min(1, Number(state.settings.volume) || 0.25));

        const length = ctx.sampleRate * 2;
        const buffer = ctx.createBuffer(1, length, ctx.sampleRate);
        const data = buffer.getChannelData(0);
        for (let i = 0; i < length; i++) data[i] = Math.random() * 2 - 1;
        const noise = ctx.createBufferSource();
        noise.buffer = buffer;
        noise.loop = true;

        const band = ctx.createBiquadFilter();
        band.type = 'bandpass';
        band.frequency.value = 2200;
        band.Q.value = 1.4;

        const clatter = ctx.createGain();
        clatter.gain.value = 0;
        const lfo = ctx.createOscillator();
        lfo.type = 'square';
        lfo.frequency.value = 7;
        const lfoGain = ctx.createGain();
        lfoGain.gain.value = 0.5;
        const offset = ctx.createConstantSource ? ctx.createConstantSource() : null;
        lfo.connect(lfoGain).connect(clatter.gain);
        if (offset) { offset.offset.value = 0.5; offset.connect(clatter.gain); offset.start(); }

        const motor = ctx.createOscillator();
        motor.type = 'sawtooth';
        motor.frequency.value = 96;
        const motorFilter = ctx.createBiquadFilter();
        motorFilter.type = 'lowpass';
        motorFilter.frequency.value = 320;
        const motorGain = ctx.createGain();
        motorGain.gain.value = 0.35;

        const master = ctx.createGain();
        master.gain.value = 0;
        master.gain.linearRampToValueAtTime(volume * 0.5, ctx.currentTime + 0.3);

        noise.connect(band).connect(clatter).connect(master);
        motor.connect(motorFilter).connect(motorGain).connect(master);
        master.connect(ctx.destination);
        noise.start();
        lfo.start();
        motor.start();
        nodes = { noise: noise, lfo: lfo, motor: motor, master: master, offset: offset };
      } catch (e) {
        nodes = null;
      }
    }

    function stop() {
      if (!nodes || !ctx) return;
      const current = nodes;
      nodes = null;
      try {
        current.master.gain.cancelScheduledValues(ctx.currentTime);
        current.master.gain.setValueAtTime(current.master.gain.value, ctx.currentTime);
        current.master.gain.linearRampToValueAtTime(0, ctx.currentTime + 0.25);
        setTimeout(function () {
          ['noise', 'lfo', 'motor', 'offset'].forEach(function (key) {
            if (current[key]) { try { current[key].stop(); } catch (e) { /* already stopped */ } }
          });
          current.master.disconnect();
        }, 320);
      } catch (e) { /* ignore */ }
    }

    return { start: start, stop: stop };
  })();

  /* ================================================================ open / close */

  function show(id, visible) {
    $(id).classList.toggle('el-visible', visible);
  }

  function requestClose() {
    closeModal(false);
    closeSelects();
    hideTooltip();
    post('el_close').catch(function () { /* page is closing anyway */ });
    applyClose();
  }

  function applyClose() {
    state.open = null;
    show('el-dashboard', false);
    show('el-viewer', false);
    show('el-connecting', false);
    $('el-modal').classList.remove('el-visible');
    modalResolve = null;
    closeSelects();
    hideTooltip();
    stopProgressTicker();
  }

  function openDashboard(data) {
    show('el-viewer', false);
    show('el-connecting', false);
    state.open = 'dashboard';
    state.dash = data;
    state.printer = data.printer;
    state.template = null;
    state.values = {};
    state.errors = {};
    state.copies = 1;
    state.previewModel = null;
    state.selectedDocId = null;
    state.docDetail = null;
    state.filter = { q: '', type: 'all' };
    state.category = 'All';
    $('el-doc-search').value = '';
    state.tab = data.templates.length ? 'create' : 'documents';
    if (data.printer.active || data.printer.queue.length) {
      const mine = (data.printer.active && data.printer.active.mine) || data.printer.queue.some(function (j) { return j.mine; });
      if (mine) state.tab = 'queue';
    }
    renderAll();
    show('el-dashboard', true);
  }

  function openViewer(view) {
    show('el-dashboard', false);
    show('el-connecting', false);
    state.open = 'viewer';
    state.viewer = view;
    const model = view.model;
    $('el-viewer-title').textContent = model.title || 'Document';
    $('el-viewer-eyebrow').textContent = view.shown ? 'Shown To You' : model.typeLabel || 'Printed Document';

    const verify = $('el-verify');
    verify.textContent = '';
    const verification = view.verification;
    if (verification) {
      verify.setAttribute('data-state', verification.state);
      const icons = { verified: 'fa-circle-check', revoked: 'fa-ban', expired: 'fa-clock', unverified: 'fa-circle-question' };
      verify.appendChild(fa(icons[verification.state] || 'fa-circle-question'));
      verify.appendChild(document.createTextNode(verification.label));
    } else {
      verify.setAttribute('data-state', 'none');
    }
    const ref = h('span', { style: 'color:var(--el-muted);font-weight:600;margin-left:6px;', text: 'Ref ' + model.id + (view.copy ? ' · Copy ' + view.copy : '') });
    verify.appendChild(ref);

    $('el-viewer-show').classList.toggle('el-hidden', !view.canShow);
    ElRender.mount($('el-viewer-frame'), model);
    show('el-viewer', true);
  }

  $('el-close').addEventListener('click', requestClose);
  $('el-viewer-close').addEventListener('click', requestClose);
  $('el-viewer-done').addEventListener('click', requestClose);
  $('el-viewer-show').addEventListener('click', function () {
    const button = $('el-viewer-show');
    withLoading(button, function () { return request('showDocument', {}); });
  });

  $('el-refresh').addEventListener('click', function () {
    withLoading($('el-refresh'), function () { return refreshDashboard(); });
  });

  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape') {
      event.preventDefault();
      if ($('el-modal').classList.contains('el-visible')) return closeModal(false);
      if (openSelects.size) return closeSelects();
      if (state.open) requestClose();
      return;
    }
    if (openSelects.size) {
      openSelects.forEach(function (api) { if (api.key(event)) event.preventDefault(); });
    }
  });

  function refreshDashboard() {
    if (state.open !== 'dashboard') return Promise.resolve();
    return request('getDashboard', {}).then(function (res) {
      if (!res.ok || state.open !== 'dashboard') return;
      state.dash = res.data;
      state.printer = res.data.printer;
      if (state.template && !res.data.templates.some(function (t) { return t.key === state.template.key; })) {
        state.template = null;
      }
      renderAll();
      if (state.selectedDocId) loadDocument(state.selectedDocId, true);
    });
  }

  /* ================================================================ render: shell */

  function renderAll() {
    renderHeader();
    renderSidebar();
    renderAlerts();
    renderTabs();
    renderCreate();
    renderDocuments();
    renderQueue();
    renderPrinterTab();
    syncProgressTicker();
  }

  function renderHeader() {
    const printer = state.printer;
    $('el-printer-name').textContent = printer.label;
    const info = STATUS[printer.status] || STATUS.ready;
    const pill = $('el-status');
    pill.textContent = info.label;
    pill.setAttribute('data-tone', info.tone);
  }

  function meter(id, data, format) {
    const node = $(id);
    const value = node.querySelector('.el-meter-value');
    const fill = node.querySelector('.el-meter-fill');
    if (!data.enabled) {
      node.setAttribute('data-level', 'off');
      value.textContent = 'Off';
      fill.style.width = '0%';
      node.setAttribute('data-tip', 'Not used on this printer');
      return;
    }
    const pct = data.max > 0 ? Math.max(0, Math.min(100, (data.value / data.max) * 100)) : 0;
    fill.style.width = pct + '%';
    value.textContent = format(data);
    node.setAttribute('data-level', data.value <= 0 ? 'empty' : (data.value <= data.low ? 'low' : 'ok'));
    node.setAttribute('data-tip', '');
  }

  function renderSidebar() {
    const p = state.printer;
    meter('el-meter-paper', p.paper, function (d) { return d.value + ' / ' + d.max; });
    meter('el-meter-ink', p.ink, function (d) { return Math.round((d.value / d.max) * 100) + '%'; });
    meter('el-meter-durability', p.durability, function (d) { return Math.round((d.value / d.max) * 100) + '%'; });

    $('el-player-name').textContent = state.dash.player.name;
    $('el-player-job').textContent = [state.dash.player.grade, state.dash.player.job].filter(Boolean).join(' · ');

    const storage = $('el-storage');
    const session = state.dash.storage !== 'database';
    storage.setAttribute('data-mode', session ? 'session' : 'database');
    $('el-storage-label').textContent = session ? 'Session Storage' : 'Database Storage';
    storage.setAttribute('data-tip', session
      ? 'No database connection. Documents are kept until the next server restart.'
      : 'Documents are stored permanently.');

    $('el-badge-documents').textContent = String(state.dash.documents.length);
    const queueCount = (p.active ? 1 : 0) + p.queue.length;
    const queueBadge = $('el-badge-queue');
    queueBadge.textContent = String(queueCount);
    queueBadge.classList.toggle('el-hidden', queueCount === 0);
  }

  function renderAlerts() {
    const box = $('el-alerts');
    box.textContent = '';
    const p = state.printer;
    const alerts = [];
    const statusAlert = STATUS_ALERTS[p.status];
    if (statusAlert) alerts.push(statusAlert);
    (p.warnings || []).forEach(function (w) { alerts.push({ text: w, icon: 'fa-triangle-exclamation', tone: 'warn' }); });
    if (state.dash.documentsError) alerts.push({ text: state.dash.documentsError, icon: 'fa-database', tone: 'bad' });
    alerts.forEach(function (a) {
      box.appendChild(h('div', { class: 'el-alert', 'data-tone': a.tone }, [fa(a.icon), h('span', { text: a.text })]));
    });
    box.classList.toggle('el-hidden', alerts.length === 0);
  }

  function renderTabs() {
    document.querySelectorAll('.el-nav-item').forEach(function (item) {
      item.classList.toggle('el-active', item.getAttribute('data-tab') === state.tab);
    });
    document.querySelectorAll('.el-panel[data-panel]').forEach(function (panel) {
      panel.classList.toggle('el-active', panel.getAttribute('data-panel') === state.tab);
    });
  }

  document.querySelectorAll('.el-nav-item').forEach(function (item) {
    item.addEventListener('click', function () {
      state.tab = item.getAttribute('data-tab');
      closeSelects();
      renderTabs();
      if (state.tab === 'documents' && state.docDetail) {
        requestAnimationFrame(function () { ElRender.fit($('el-doc-frame-detail') || document.body); });
      }
      if (state.tab === 'create' && state.previewModel) {
        requestAnimationFrame(function () { ElRender.fit($('el-editor-preview')); });
      }
    });
  });

  function emptyState(iconName, title, text, action) {
    return h('div', { class: 'el-empty' }, [
      h('div', { class: 'el-empty-icon' }, [fa(iconName)]),
      h('div', { class: 'el-empty-title', text: title }),
      text ? h('div', { class: 'el-empty-text', text: text }) : null,
      action || null,
    ]);
  }

  /* ================================================================ render: create */

  function renderCreate() {
    const pick = $('el-create-pick');
    const edit = $('el-create-edit');
    if (state.template) {
      pick.classList.add('el-hidden');
      edit.classList.remove('el-hidden');
      renderEditor();
    } else {
      edit.classList.add('el-hidden');
      pick.classList.remove('el-hidden');
      renderTemplateGrid();
    }
  }

  function renderTemplateGrid() {
    const templates = state.dash.templates;
    const chips = $('el-category-chips');
    const grid = $('el-template-grid');
    chips.textContent = '';
    grid.textContent = '';

    if (!templates.length) {
      grid.style.display = 'flex';
      grid.appendChild(emptyState('fa-lock', 'No document types available',
        'Your role cannot create documents on this printer. Saved documents remain available in the Documents tab.'));
      return;
    }
    grid.style.display = '';

    const categories = ['All'];
    templates.forEach(function (t) { if (categories.indexOf(t.category) === -1) categories.push(t.category); });
    if (categories.indexOf(state.category) === -1) state.category = 'All';
    if (categories.length > 2) {
      categories.forEach(function (category) {
        chips.appendChild(h('button', {
          class: 'el-chip' + (category === state.category ? ' el-active' : ''),
          text: category,
          onClick: function () { state.category = category; renderTemplateGrid(); },
        }));
      });
    }

    templates.filter(function (t) { return state.category === 'All' || t.category === state.category; })
      .forEach(function (t) {
        const foot = [h('span', null, [fa('fa-tag'), money(t.cost)])];
        if (t.paper) foot.push(h('span', null, [fa('fa-regular fa-file'), plural(t.paper, 'sheet')]));
        if (t.ink) foot.push(h('span', null, [fa('fa-droplet'), t.ink + ' ink']));
        if (t.expiresDays) foot.push(h('span', null, [fa('fa-clock'), t.expiresDays + ' days']));
        grid.appendChild(h('button', { class: 'el-template', onClick: function () { selectTemplate(t); } }, [
          h('div', { class: 'el-template-top' }, [
            h('div', { class: 'el-template-icon' }, [fa(t.icon)]),
            h('span', { class: 'el-tag' + (t.official ? ' el-tag-accent' : ''), text: t.official ? 'Official' : t.category }),
          ]),
          h('div', null, [
            h('div', { class: 'el-template-name', text: t.label }),
            h('div', { class: 'el-template-desc', text: t.description }),
          ]),
          h('div', { class: 'el-template-foot' }, foot),
        ]));
      });
  }

  function selectTemplate(template) {
    state.template = template;
    state.values = {};
    state.errors = {};
    state.copies = 1;
    state.previewModel = null;
    state.previewDirty = false;
    renderCreate();
  }

  $('el-editor-back').addEventListener('click', function () {
    state.template = null;
    closeSelects();
    renderCreate();
  });

  function renderEditor() {
    const t = state.template;
    $('el-editor-title').textContent = t.label;
    $('el-editor-sub').textContent = t.description;

    const container = $('el-editor-fields');
    container.textContent = '';
    t.fields.forEach(function (field) { container.appendChild(buildField(field)); });

    renderCopies();
    renderPreviewFrame();
  }

  function buildField(field) {
    const wrap = h('div', { class: 'el-field' + (state.errors[field.name] ? ' el-invalid' : ''), 'data-field': field.name });
    const labelChildren = [h('span', null, [field.label, field.required ? h('span', { class: 'el-required', text: '*' }) : null])];
    let counter = null;
    if ((field.type === 'text' || field.type === 'textarea') && field.max) {
      counter = h('span', { class: 'el-counter' });
      labelChildren.push(counter);
    }
    wrap.appendChild(h('label', { class: 'el-label' }, labelChildren));

    const current = state.values[field.name];
    let control;

    function onValue(value) {
      if (value === '' || value === undefined) delete state.values[field.name];
      else state.values[field.name] = value;
      if (state.errors[field.name]) {
        delete state.errors[field.name];
        wrap.classList.remove('el-invalid');
        const error = wrap.querySelector('.el-field-error');
        if (error) error.remove();
      }
      if (counter) updateCounter();
      markPreviewDirty();
    }

    function updateCounter() {
      const length = (state.values[field.name] || '').length;
      counter.textContent = length + ' / ' + field.max;
      counter.classList.toggle('el-over', length > field.max);
    }

    if (field.type === 'textarea') {
      control = h('textarea', { class: 'el-textarea', maxlength: field.max || 2000, placeholder: field.placeholder || '' });
      control.value = current || '';
      control.addEventListener('input', function () { onValue(control.value); });
      wrap.appendChild(control);
    } else if (field.type === 'select') {
      control = h('div');
      wrap.appendChild(control);
      createSelect(control, {
        value: current,
        placeholder: field.placeholder || 'Select ' + field.label.toLowerCase(),
        options: (field.options || []).map(function (o) { return { value: o, label: o }; }),
        onChange: onValue,
      });
    } else if (field.type === 'citizen') {
      control = h('input', { class: 'el-input', type: 'text', maxlength: 16, placeholder: field.placeholder || 'Citizen ID', spellcheck: 'false' });
      control.value = current || '';
      control.addEventListener('input', function () {
        control.value = control.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
        onValue(control.value);
      });
      wrap.appendChild(h('div', { class: 'el-input-icon' }, [fa('fa-id-card'), control]));
      wrap.appendChild(h('div', { class: 'el-field-hint', text: 'The name and details are filled in by the server.' }));
    } else if (field.type === 'number') {
      control = h('input', {
        class: 'el-input', type: 'number', min: field.min, max: field.max,
        step: field.money ? '0.01' : '1', placeholder: field.placeholder || (field.money ? '0.00' : '0'),
      });
      control.value = current !== undefined ? current : '';
      control.addEventListener('input', function () { onValue(control.value === '' ? '' : Number(control.value)); });
      wrap.appendChild(field.money ? h('div', { class: 'el-input-icon' }, [fa('fa-dollar-sign'), control]) : control);
    } else if (field.type === 'date') {
      control = h('input', { class: 'el-input', type: 'date', min: '1900-01-01', max: '2200-12-31' });
      control.value = current || '';
      control.addEventListener('input', function () { onValue(control.value); });
      wrap.appendChild(control);
    } else {
      control = h('input', { class: 'el-input', type: 'text', maxlength: field.max || 255, placeholder: field.placeholder || '' });
      control.value = current || '';
      control.addEventListener('input', function () { onValue(control.value); });
      wrap.appendChild(control);
    }

    if (counter) updateCounter();
    if (state.errors[field.name]) {
      wrap.appendChild(h('div', { class: 'el-field-error' }, [fa('fa-circle-exclamation'), state.errors[field.name]]));
    }
    return wrap;
  }

  // Mirrors the server rules for instant feedback. The server validates again.
  function validateLocally() {
    const errors = {};
    state.template.fields.forEach(function (field) {
      const value = state.values[field.name];
      const empty = value === undefined || value === null || String(value).trim() === '';
      if (empty) {
        if (field.required) errors[field.name] = 'This field is required.';
        return;
      }
      if (field.type === 'text' || field.type === 'textarea') {
        const length = String(value).trim().length;
        if (field.min && length < field.min) errors[field.name] = 'Must be at least ' + field.min + ' characters.';
        else if (field.max && length > field.max) errors[field.name] = 'Must be at most ' + field.max + ' characters.';
      } else if (field.type === 'number') {
        const n = Number(value);
        if (!isFinite(n)) errors[field.name] = 'Enter a valid number.';
        else if (field.min !== undefined && field.min !== null && n < field.min) errors[field.name] = 'Must be at least ' + field.min + '.';
        else if (field.max !== undefined && field.max !== null && n > field.max) errors[field.name] = 'Must be at most ' + field.max + '.';
      } else if (field.type === 'citizen' && !/^[A-Z0-9]{1,16}$/.test(String(value))) {
        errors[field.name] = 'Enter a valid citizen ID.';
      }
    });
    state.errors = errors;
    return Object.keys(errors).length === 0;
  }

  function applyFieldErrors(fieldErrors) {
    state.errors = fieldErrors || {};
    renderEditor();
    const first = document.querySelector('#el-editor-fields .el-invalid');
    if (first) first.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  function renderCopies() {
    const max = Math.max(1, state.dash.settings.maxCopies || 1);
    state.copies = Math.max(1, Math.min(max, state.copies));
    $('el-copies-value').textContent = copiesLabel(state.copies);
    $('el-copies-minus').disabled = state.copies <= 1;
    $('el-copies-plus').disabled = state.copies >= max;

    const t = state.template;
    const cost = $('el-editor-cost');
    cost.textContent = '';
    cost.appendChild(h('span', null, [fa('fa-tag'), 'Per copy ', h('strong', { text: money(t.cost) })]));
    if (t.paper) cost.appendChild(h('span', null, [fa('fa-regular fa-file'), h('strong', { text: String(t.paper * state.copies) }), ' sheets']));
    if (t.ink) cost.appendChild(h('span', null, [fa('fa-droplet'), h('strong', { text: String(t.ink * state.copies) }), ' ink']));
    cost.appendChild(h('span', null, [fa('fa-receipt'), 'Total ', h('strong', { text: money(t.cost * state.copies) })]));

    const printBlock = printBlockReason();
    setDisabled($('el-btn-save-print'), !!printBlock, printBlock);
  }

  // Reason why the printer cannot print at the moment (does not cover queueing).
  function printBlockReason() {
    const status = state.printer.status;
    if (status === 'offline') return 'This printer is offline.';
    if (status === 'maintenance') return 'The printer is in maintenance mode.';
    if (status === 'broken') return 'The printer requires maintenance.';
    if (status === 'repairing') return 'The printer is being repaired.';
    return null;
  }

  $('el-copies-minus').addEventListener('click', function () { state.copies -= 1; renderCopies(); });
  $('el-copies-plus').addEventListener('click', function () { state.copies += 1; renderCopies(); });

  function markPreviewDirty() {
    if (state.previewModel && !state.previewDirty) {
      state.previewDirty = true;
      renderPreviewFrame();
    }
  }

  function renderPreviewFrame() {
    const frame = $('el-editor-preview');
    if (!state.previewModel) {
      frame.textContent = '';
      frame.appendChild(emptyState('fa-regular fa-file-lines', 'No preview yet',
        'Generate a preview to see the document exactly as it will be printed. The server fills in issuer, recipient and reference details.'));
      return;
    }
    if (!frame.querySelector('.el-doc') || frame.__elModel !== state.previewModel) {
      ElRender.mount(frame, state.previewModel);
      frame.__elModel = state.previewModel;
    }
    let note = frame.querySelector('.el-preview-outdated');
    if (state.previewDirty && !note) {
      note = h('div', { class: 'el-alert el-preview-outdated', style: 'position:sticky;top:0;z-index:2;margin:0 auto 12px;width:max-content;' },
        [fa('fa-rotate'), h('span', { text: 'Preview outdated - generate it again to see your changes.' })]);
      frame.insertBefore(note, frame.firstChild);
    } else if (!state.previewDirty && note) {
      note.remove();
    }
  }

  function documentPayload() {
    return { docType: state.template.key, fields: Object.assign({}, state.values) };
  }

  $('el-btn-preview').addEventListener('click', function () {
    if (!state.template) return;
    if (!validateLocally()) return applyFieldErrors(state.errors);
    withLoading($('el-btn-preview'), function () {
      return request('previewDocument', documentPayload()).then(function (res) {
        if (!res.ok) { if (res.fieldErrors) applyFieldErrors(res.fieldErrors); return; }
        state.previewModel = res.data.model;
        state.previewDirty = false;
        state.errors = {};
        renderPreviewFrame();
      });
    });
  });

  function saveDocument(button, thenPrint) {
    if (!state.template) return;
    if (!validateLocally()) return applyFieldErrors(state.errors);
    const copies = state.copies;
    withLoading(button, function () {
      return request('createDocument', documentPayload()).then(function (res) {
        if (!res.ok) { if (res.fieldErrors) applyFieldErrors(res.fieldErrors); return; }
        const detail = res.data;
        state.dash.documents.unshift(detail.summary);
        state.selectedDocId = detail.summary.id;
        state.docDetail = detail;
        state.template = null;
        state.previewModel = null;
        renderCreate();
        renderSidebar();
        renderDocuments();

        if (!thenPrint) {
          state.tab = 'documents';
          renderTabs();
          return;
        }
        return request('print', { documentId: detail.summary.id, copies: copies }).then(function (printRes) {
          state.tab = printRes.ok ? 'queue' : 'documents';
          renderTabs();
          renderQueue();
        });
      });
    });
  }

  $('el-btn-save').addEventListener('click', function () { saveDocument($('el-btn-save'), false); });
  $('el-btn-save-print').addEventListener('click', function () {
    if (!isDisabled($('el-btn-save-print'))) saveDocument($('el-btn-save-print'), true);
  });

  /* ================================================================ render: documents */

  const typeFilter = { api: null };

  function filteredDocuments() {
    const q = state.filter.q.trim().toLowerCase();
    return state.dash.documents.filter(function (d) {
      if (state.filter.type !== 'all' && d.type !== state.filter.type) return false;
      if (!q) return true;
      return (d.title + ' ' + d.id + ' ' + d.issuerName + ' ' + d.typeLabel).toLowerCase().indexOf(q) !== -1;
    });
  }

  function renderDocuments() {
    const docs = state.dash.documents;
    const types = [{ value: 'all', label: 'All document types' }];
    docs.forEach(function (d) {
      if (!types.some(function (t) { return t.value === d.type; })) types.push({ value: d.type, label: d.typeLabel });
    });
    if (!types.some(function (t) { return t.value === state.filter.type; })) state.filter.type = 'all';
    typeFilter.api = createSelect($('el-doc-type-filter'), {
      value: state.filter.type,
      options: types,
      onChange: function (value) { state.filter.type = value; renderDocumentList(); },
    });

    $('el-docs-sub').textContent = state.dash.storage === 'database'
      ? 'Documents you issued, received or may access.'
      : 'Session storage: documents are kept until the next server restart.';
    renderDocumentList();
    renderDocumentDetail();
  }

  function renderDocumentList() {
    const list = $('el-doc-list');
    list.textContent = '';
    if (state.dash.documentsError) {
      list.appendChild(emptyState('fa-database', 'Documents unavailable', state.dash.documentsError,
        btn({ label: 'Try Again', icon: 'fa-rotate-right', size: 'el-btn-sm', onClick: function (b) { withLoading(b, refreshDashboard); } })));
      return;
    }
    const docs = filteredDocuments();
    if (!state.dash.documents.length) {
      list.appendChild(emptyState('fa-regular fa-folder-open', 'No documents yet', 'Documents you create or receive will appear here.'));
      return;
    }
    if (!docs.length) {
      list.appendChild(emptyState('fa-magnifying-glass', 'No matching documents', 'Try a different search or document type.'));
      return;
    }
    docs.forEach(function (d) {
      const statusLabel = d.status === 'active' ? 'Valid' : (d.status === 'revoked' ? 'Revoked' : 'Expired');
      list.appendChild(h('button', {
        class: 'el-doc-item' + (d.id === state.selectedDocId ? ' el-active' : ''),
        onClick: function () { loadDocument(d.id); },
      }, [
        h('div', { class: 'el-doc-item-icon' }, [fa(d.icon)]),
        h('div', { class: 'el-doc-item-text' }, [
          h('div', { class: 'el-doc-item-title', text: d.title }),
          h('div', { class: 'el-doc-item-meta', text: d.typeLabel + ' · ' + d.createdAt + ' · ' + d.relation }),
        ]),
        h('span', { class: 'el-doc-item-status', 'data-status': d.status, text: statusLabel }),
      ]));
    });
  }

  let searchTimer = null;
  $('el-doc-search').addEventListener('input', function () {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(function () {
      state.filter.q = $('el-doc-search').value;
      renderDocumentList();
    }, 150);
  });

  function loadDocument(id, silent) {
    if (!silent) {
      state.selectedDocId = id;
      state.docLoading = true;
      state.docCopies = 1;
      renderDocumentList();
      renderDocumentDetail();
    }
    return request('getDocument', { documentId: id }).then(function (res) {
      if (state.selectedDocId !== id) return;
      state.docLoading = false;
      if (!res.ok) {
        if (!silent) { state.docDetail = null; state.selectedDocId = null; }
        renderDocumentList();
        renderDocumentDetail();
        return;
      }
      state.docDetail = res.data;
      replaceSummary(res.data.summary);
      renderDocumentList();
      renderDocumentDetail();
    });
  }

  function replaceSummary(summary) {
    if (!summary) return;
    const docs = state.dash.documents;
    for (let i = 0; i < docs.length; i++) {
      if (docs[i].id === summary.id) { docs[i] = summary; return; }
    }
  }

  function printDisabledReason(summary) {
    if (summary.status === 'revoked') return 'This document has been revoked.';
    if (summary.status === 'expired') return 'This document has expired.';
    if (summary.maxPrints !== null && summary.maxPrints !== undefined && summary.printCount >= summary.maxPrints) return 'Print limit reached for this document.';
    if (!summary.printerAllows) return 'This printer cannot print this document type.';
    if (!summary.canPrint) return 'You are not allowed to print this document.';
    return printBlockReason();
  }

  function renderDocumentDetail() {
    const box = $('el-doc-detail');
    box.textContent = '';

    if (state.docLoading) {
      box.appendChild(h('div', { class: 'el-empty' }, [h('div', { class: 'el-spinner' }), h('div', { class: 'el-empty-text', text: 'Loading document' })]));
      return;
    }
    if (!state.docDetail) {
      box.appendChild(emptyState('fa-regular fa-file-lines', 'Select a document', 'Choose a document from the list to preview, print or manage it.'));
      return;
    }

    const summary = state.docDetail.summary;
    const head = h('div', { class: 'el-preview-head' }, [
      h('span', { class: 'el-preview-title', style: 'min-width:0;' }, [fa(summary.icon), h('span', { style: 'white-space:nowrap;overflow:hidden;text-overflow:ellipsis;', text: summary.title })]),
      h('span', { class: 'el-tag' + (summary.status === 'active' ? ' el-tag-accent' : ''), text: summary.id }),
    ]);
    const frame = h('div', { class: 'el-doc-frame', id: 'el-doc-frame-detail' });
    box.appendChild(head);
    box.appendChild(frame);
    ElRender.mount(frame, state.docDetail.model);

    const max = Math.max(1, state.dash.settings.maxCopies || 1);
    const remaining = summary.maxPrints !== null && summary.maxPrints !== undefined ? Math.max(0, summary.maxPrints - summary.printCount) : max;
    const copyLimit = Math.max(1, Math.min(max, remaining));
    state.docCopies = Math.max(1, Math.min(copyLimit, state.docCopies));

    const reason = printDisabledReason(summary);
    const copiesText = h('span', { text: copiesLabel(state.docCopies) });
    const minus = h('button', { disabled: state.docCopies <= 1 }, [fa('fa-minus')]);
    const plus = h('button', { disabled: state.docCopies >= copyLimit }, [fa('fa-plus')]);
    minus.addEventListener('click', function () { state.docCopies -= 1; renderDocumentDetail(); });
    plus.addEventListener('click', function () { state.docCopies += 1; renderDocumentDetail(); });

    const actions = [h('div', { class: 'el-stepper', 'data-tip': 'Copies' }, [minus, copiesText, plus]), h('div', { class: 'el-spacer' })];
    if (summary.canRevoke) {
      actions.push(btn({
        label: 'Revoke', icon: 'fa-ban', variant: 'el-btn-danger',
        onClick: function (b) {
          confirmDialog({
            title: 'Revoke document?',
            text: 'Revoking ' + summary.title + ' (' + summary.id + ') marks every printed copy as revoked. This cannot be undone.',
            confirmLabel: 'Revoke', tone: 'danger', icon: 'fa-ban',
          }).then(function (ok) {
            if (!ok) return;
            withLoading(b, function () {
              return request('revokeDocument', { documentId: summary.id }).then(function (res) {
                if (!res.ok) return;
                state.docDetail = res.data;
                replaceSummary(res.data.summary);
                renderDocumentList();
                renderDocumentDetail();
              });
            });
          });
        },
      }));
    }
    actions.push(btn({
      label: summary.printLabel, icon: 'fa-print', variant: 'el-btn-primary', disabled: !!reason, tip: reason,
      onClick: function (b) {
        withLoading(b, function () {
          return request('print', { documentId: summary.id, copies: state.docCopies }).then(function (res) {
            if (res.ok) { state.tab = 'queue'; renderTabs(); renderQueue(); }
          });
        });
      },
    }));

    const metaParts = [
      h('span', null, ['Issued by ', h('strong', { text: summary.issuerName })]),
      h('span', null, ['Created ', h('strong', { text: summary.createdAt })]),
      h('span', null, ['Printed ', h('strong', { text: summary.printCount + (summary.maxPrints ? ' / ' + summary.maxPrints : '') })]),
    ];
    box.appendChild(h('div', { class: 'el-doc-detail-foot' }, [
      h('div', { class: 'el-doc-detail-meta' }, metaParts),
      h('div', { class: 'el-actions' }, actions),
    ]));
  }

  /* ================================================================ render: queue & progress */

  function activeProgress() {
    const active = state.printer && state.printer.active;
    if (!active) return null;
    const local = state.progress;
    if (!local || local.jobId !== active.id) return { pct: active.progress || 0, remaining: active.remaining || 0 };
    const elapsed = Date.now() - local.receivedAt;
    const remaining = Math.max(0, local.remaining - elapsed);
    const pct = local.duration > 0 ? Math.min(99, Math.floor(((local.duration - remaining) / local.duration) * 100)) : local.progress;
    return { pct: Math.max(local.progress, pct), remaining: remaining };
  }

  function setLocalProgress(jobId, progress, remaining, duration) {
    state.progress = { jobId: jobId, progress: progress || 0, remaining: remaining || 0, duration: duration || 0, receivedAt: Date.now() };
  }

  let ticker = null;
  function syncProgressTicker() {
    const active = state.printer && state.printer.active;
    if (active && (!state.progress || state.progress.jobId !== active.id)) {
      setLocalProgress(active.id, active.progress, active.remaining, active.duration);
    }
    if (active && state.open === 'dashboard') {
      if (!ticker) ticker = setInterval(paintProgress, 250);
    } else {
      stopProgressTicker();
    }
    paintProgress();
  }

  function stopProgressTicker() {
    if (ticker) { clearInterval(ticker); ticker = null; }
  }

  function paintProgress() {
    const active = state.printer && state.printer.active;
    const strip = $('el-strip');
    if (!active) { strip.classList.add('el-hidden'); return; }
    const p = activeProgress();
    strip.classList.remove('el-hidden');
    $('el-strip-text').textContent = active.mine ? 'Printing ' + active.title : 'Printer busy with another job';
    $('el-strip-fill').style.width = p.pct + '%';
    $('el-strip-pct').textContent = p.pct + '%';

    const fill = document.getElementById('el-job-fill');
    if (fill) {
      fill.style.width = p.pct + '%';
      $('el-job-pct').textContent = p.pct + '%';
      $('el-job-remaining').textContent = p.remaining > 0 ? 'About ' + seconds(p.remaining) + ' remaining' : 'Finishing';
    }
  }

  function cancelJob(job, button) {
    confirmDialog({
      title: 'Cancel print job?',
      text: job.state === 'printing'
        ? 'Printing stops and reserved paper and ink return to the printer. Nothing is charged.'
        : 'The job is removed from the queue. Nothing is charged.',
      confirmLabel: 'Cancel Job', tone: 'danger', icon: 'fa-xmark',
    }).then(function (ok) {
      if (!ok) return;
      withLoading(button, function () { return request('cancelJob', { jobId: job.id }); });
    });
  }

  function renderQueue() {
    const box = $('el-queue');
    box.textContent = '';
    const p = state.printer;

    $('el-queue-sub').textContent = p.queueEnabled
      ? 'Live progress reported by the printer. Up to ' + p.queueMax + ' jobs can wait in line.'
      : 'Queue disabled: the printer accepts one job at a time.';

    if (!p.active && !p.queue.length) {
      box.appendChild(emptyState('fa-layer-group', 'The queue is empty', 'Print a document and its progress will appear here.'));
      return;
    }

    if (p.active) {
      const a = p.active;
      const card = h('div', { class: 'el-card el-card-glow el-job-active' }, [
        h('div', { class: 'el-job-active-head' }, [
          h('div', { class: 'el-job-active-icon' }, [fa('fa-print')]),
          h('div', { style: 'min-width:0;' }, [
            h('div', { class: 'el-job-active-title', text: a.mine ? a.title : 'Print job in progress' }),
            h('div', { class: 'el-job-active-sub', text: a.mine ? (a.typeLabel || 'Document') + ' · ' + copiesLabel(a.copies) : 'Started by another user' }),
          ]),
          h('div', { class: 'el-job-active-pct', id: 'el-job-pct', text: '0%' }),
        ]),
        h('div', { class: 'el-progress' }, [h('div', { class: 'el-progress-fill', id: 'el-job-fill' })]),
        h('div', { class: 'el-job-active-foot' }, [
          h('span', { id: 'el-job-remaining', text: '' }),
          a.mine ? btn({ label: 'Cancel', icon: 'fa-xmark', variant: 'el-btn-danger', size: 'el-btn-sm', onClick: function (b) { cancelJob(a, b); } }) : null,
        ]),
      ]);
      box.appendChild(card);
    }

    if (p.queue.length) {
      box.appendChild(h('div', { class: 'el-section-label', style: 'padding-left:2px;', text: 'Waiting' }));
      const list = h('div', { class: 'el-queue-list' });
      p.queue.forEach(function (job, index) {
        list.appendChild(h('div', { class: 'el-queue-item' + (job.mine ? ' el-mine' : '') }, [
          h('div', { class: 'el-queue-pos', text: String(index + 1) }),
          h('div', { class: 'el-queue-text' }, [
            h('div', { class: 'el-queue-title', text: job.mine ? job.title : 'Print job' }),
            h('div', { class: 'el-queue-meta', text: (job.mine ? 'Your job' : 'Another user') + ' · ' + copiesLabel(job.copies) }),
          ]),
          job.mine ? btn({ label: 'Cancel', icon: 'fa-xmark', variant: 'el-btn-ghost', size: 'el-btn-sm', onClick: function (b) { cancelJob(job, b); } }) : null,
        ]));
      });
      box.appendChild(list);
    }
    paintProgress();
  }

  /* ================================================================ render: printer tab */

  function supplyCard(kind) {
    const p = state.printer;
    const data = p[kind];
    const perms = state.dash.permissions;
    const supplies = state.dash.supplies;
    const isPaper = kind === 'paper';
    const items = isPaper ? supplies.paperItems : supplies.inkItems;
    const perItem = isPaper ? supplies.paperPerItem : supplies.inkPerItem;

    const card = h('div', { class: 'el-card el-maint-card' }, [
      h('div', { class: 'el-maint-head' }, [
        h('div', { class: 'el-maint-icon' }, [fa(isPaper ? 'fa-regular fa-file' : 'fa-droplet')]),
        h('div', null, [
          h('div', { class: 'el-maint-name', text: isPaper ? 'Paper Tray' : 'Ink Cartridge' }),
          h('div', { class: 'el-maint-sub', text: data.enabled ? (isPaper ? 'Sheets available' : 'Ink level') : 'Not used on this printer' }),
        ]),
      ]),
    ]);
    if (!data.enabled) return card;

    const pct = data.max > 0 ? Math.round((data.value / data.max) * 100) : 0;
    card.appendChild(h('div', { class: 'el-maint-big' }, isPaper
      ? [String(data.value), h('small', { text: '/ ' + data.max + ' sheets' })]
      : [pct + '%', h('small', { text: data.value + ' / ' + data.max + ' units' })]));
    const level = data.value <= 0 ? 'empty' : (data.value <= data.low ? 'low' : 'ok');
    card.appendChild(h('div', { class: 'el-meter', 'data-level': level, style: 'padding:0;border:none;background:none;' }, [
      h('div', { class: 'el-meter-track' }, [h('div', { class: 'el-meter-fill', style: 'width:' + pct + '%' })]),
    ]));

    if (perms.refill) {
      const full = data.value >= data.max;
      const reason = full ? 'The printer is already full.' : (items <= 0 ? (isPaper ? 'You have no printer paper.' : 'You have no printer ink.') : null);
      card.appendChild(h('div', { class: 'el-maint-row' }, [
        h('span', { class: 'el-maint-note', text: 'You carry ' + items + ' · +' + perItem + (isPaper ? ' sheets' : ' units') + ' each' }),
        btn({
          label: isPaper ? 'Load Paper' : 'Load Ink', icon: 'fa-plus', variant: 'el-btn-primary', size: 'el-btn-sm',
          disabled: !!reason, tip: reason,
          onClick: function (b) {
            withLoading(b, function () {
              return request('refill', { kind: kind }).then(function (res) {
                if (res.ok && res.data) {
                  supplies.paperItems = res.data.paperItems;
                  supplies.inkItems = res.data.inkItems;
                  renderPrinterTab();
                }
              });
            });
          },
        }),
      ]));
    }
    return card;
  }

  function renderPrinterTab() {
    const box = $('el-maint');
    box.textContent = '';
    const p = state.printer;
    const perms = state.dash.permissions;

    box.appendChild(supplyCard('paper'));
    box.appendChild(supplyCard('ink'));

    // Condition
    const d = p.durability;
    const condition = h('div', { class: 'el-card el-maint-card' }, [
      h('div', { class: 'el-maint-head' }, [
        h('div', { class: 'el-maint-icon' }, [fa('fa-gear')]),
        h('div', null, [
          h('div', { class: 'el-maint-name', text: 'Condition' }),
          h('div', { class: 'el-maint-sub', text: d.enabled ? 'Wears down with every printed copy' : 'Durability is disabled on this server' }),
        ]),
      ]),
    ]);
    if (d.enabled) {
      const pct = d.max > 0 ? Math.round((d.value / d.max) * 100) : 0;
      condition.appendChild(h('div', { class: 'el-maint-big' }, [pct + '%', h('small', { text: d.value <= 0 ? 'Broken' : (d.value <= d.low ? 'Needs service' : 'Good') })]));
      condition.appendChild(h('div', { class: 'el-meter', 'data-level': d.value <= 0 ? 'empty' : (d.value <= d.low ? 'low' : 'ok'), style: 'padding:0;border:none;background:none;' }, [
        h('div', { class: 'el-meter-track' }, [h('div', { class: 'el-meter-fill', style: 'width:' + pct + '%' })]),
      ]));
      if (p.status === 'repairing') {
        condition.appendChild(h('div', { class: 'el-maint-row' }, [
          h('span', { class: 'el-maint-note', text: 'Repair in progress' + (p.repairRemaining ? ' · about ' + seconds(p.repairRemaining) : '') }),
          h('div', { class: 'el-spinner' }),
        ]));
      } else if (perms.repair) {
        const reason = d.value >= d.max ? 'The printer is in perfect condition.' : (p.active ? 'Wait until the current job finishes.' : null);
        condition.appendChild(h('div', { class: 'el-maint-row' }, [
          h('span', { class: 'el-maint-note', text: 'Repair cost ' + state.dash.settings.repairCost }),
          btn({
            label: 'Repair', icon: 'fa-wrench', variant: 'el-btn-primary', size: 'el-btn-sm', disabled: !!reason, tip: reason,
            onClick: function (b) {
              confirmDialog({
                title: 'Repair printer?',
                text: 'Restores the printer to full condition for ' + state.dash.settings.repairCost + '. The printer is unavailable for about ' + seconds(state.dash.settings.repairDuration || 0) + '.',
                confirmLabel: 'Repair', icon: 'fa-wrench',
              }).then(function (ok) {
                if (ok) withLoading(b, function () { return request('repair', {}); });
              });
            },
          }),
        ]));
      }
    }
    box.appendChild(condition);

    // Maintenance mode
    if (perms.maintenance) {
      const toggle = h('button', { class: 'el-toggle', role: 'switch', 'aria-checked': p.maintenance ? 'true' : 'false', 'aria-label': 'Maintenance mode' });
      toggle.addEventListener('click', function () {
        const next = !p.maintenance;
        const run = function () {
          toggle.disabled = true;
          request('setMaintenance', { enabled: next }).finally(function () { toggle.disabled = false; });
        };
        if (next && p.queue.length) {
          confirmDialog({
            title: 'Enable maintenance mode?',
            text: 'Printing pauses and waiting jobs are cancelled. The current job is allowed to finish.',
            confirmLabel: 'Enable', icon: 'fa-screwdriver-wrench',
          }).then(function (ok) { if (ok) run(); });
        } else {
          run();
        }
      });
      box.appendChild(h('div', { class: 'el-card el-maint-card' }, [
        h('div', { class: 'el-maint-head' }, [
          h('div', { class: 'el-maint-icon' }, [fa('fa-screwdriver-wrench')]),
          h('div', { style: 'flex:1;' }, [
            h('div', { class: 'el-maint-name', text: 'Maintenance Mode' }),
            h('div', { class: 'el-maint-sub', text: p.maintenance ? 'Printing is paused' : 'Printer accepts jobs' }),
          ]),
          toggle,
        ]),
        h('div', { class: 'el-maint-note', text: 'Pauses printing for everyone while the printer is serviced.' }),
      ]));
    }

    // Removal (placed printers)
    if (perms.remove) {
      box.appendChild(h('div', { class: 'el-card el-maint-card' }, [
        h('div', { class: 'el-maint-head' }, [
          h('div', { class: 'el-maint-icon' }, [fa('fa-box-open')]),
          h('div', null, [
            h('div', { class: 'el-maint-name', text: 'Portable Printer' }),
            h('div', { class: 'el-maint-sub', text: 'Pick up this printer' }),
          ]),
        ]),
        h('div', { class: 'el-maint-note', text: 'Running and waiting jobs are cancelled. Loaded paper and ink are lost.' }),
        h('div', { class: 'el-actions' }, [
          btn({
            label: 'Pick Up Printer', icon: 'fa-hand', variant: 'el-btn-danger', size: 'el-btn-sm',
            onClick: function (b) {
              confirmDialog({
                title: 'Pick up printer?',
                text: 'The printer is removed from the world and returned to your inventory.',
                confirmLabel: 'Pick Up', tone: 'danger', icon: 'fa-hand',
              }).then(function (ok) {
                if (ok) withLoading(b, function () { return request('removePrinter', {}); });
              });
            },
          }),
        ]),
      ]));
    }
  }

  /* ================================================================ live updates */

  function onPrinterState(printerState) {
    if (state.open !== 'dashboard' || !state.printer || printerState.id !== state.printer.id) return;
    const previousActive = state.printer.active && state.printer.active.id;
    const previousStatus = state.printer.status;
    state.printer = printerState;
    if (!printerState.active || printerState.active.id !== previousActive) state.progress = null;
    renderHeader();
    renderSidebar();
    renderAlerts();
    renderQueue();
    renderPrinterTab();
    if (state.template) renderCopies();
    // Only rebuild the document detail when the print availability changed (avoids flicker).
    if (state.docDetail && previousStatus !== printerState.status) renderDocumentDetail();
    syncProgressTicker();
  }

  function onJobEvent(event) {
    if (event.state === 'started') {
      PrinterSound.start();
    } else if (event.state === 'completed' || event.state === 'failed' || event.state === 'cancelled') {
      PrinterSound.stop();
    }

    if (state.open !== 'dashboard' || !state.printer || event.printerId !== state.printer.id) return;

    if (event.state === 'started' || event.state === 'progress') {
      setLocalProgress(event.jobId, event.progress, event.remaining, event.duration);
      paintProgress();
    } else if (event.state === 'completed' || event.state === 'failed' || event.state === 'cancelled') {
      state.progress = null;
      // Print counts and carried supplies changed: reload confirmed data from the server.
      refreshDashboard();
    }
  }

  /* ================================================================ messages from Lua */

  window.addEventListener('message', function (event) {
    const msg = event.data || {};
    const data = msg.data;
    switch (msg.action) {
      case 'openDashboard': openDashboard(data); break;
      case 'openViewer': openViewer(data); break;
      case 'close': applyClose(); break;
      case 'loading':
        if (data && data.label) $('el-connecting-label').textContent = data.label;
        show('el-connecting', !!data);
        break;
      case 'printerState': onPrinterState(data); break;
      case 'job': onJobEvent(data || {}); break;
      case 'notify':
        if (data && data.message) toast(data.message, data.type, data.duration);
        break;
      case 'placement': {
        const pill = $('el-placement');
        if (!data || !data.show) { show('el-placement', false); break; }
        pill.setAttribute('data-valid', data.valid ? 'true' : 'false');
        $('el-placement-state').textContent = data.valid ? 'Valid position' : 'Invalid position';
        show('el-placement', true);
        break;
      }
      default: break;
    }
  });

  post('el_ready').then(function (settings) {
    if (settings) Object.assign(state.settings, settings);
  }).catch(function () { /* running outside FiveM */ });
})();
