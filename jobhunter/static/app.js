/* Job-Hunter dashboard: theme, toasts, keyboard shortcuts, loading states, sticky filters,
   quick status changes and bulk actions. Writes go to /api/v1 as JSON (same origin; the
   server rejects cross-origin writes and non-JSON API bodies). Nothing here sends e-mail. */
(function () {
  'use strict';
  const BASE = document.body.dataset.base || '';
  const $ = (sel, root) => (root || document).querySelector(sel);
  const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));

  // ---- theme ---------------------------------------------------------------
  const themeBtn = $('#theme-toggle');
  themeBtn && themeBtn.addEventListener('click', () => {
    const root = document.documentElement;
    const dark = root.dataset.theme ? root.dataset.theme === 'dark'
                                    : matchMedia('(prefers-color-scheme: dark)').matches;
    root.dataset.theme = dark ? 'light' : 'dark';
    try { localStorage.setItem('jh-theme', root.dataset.theme); } catch (e) {}
  });

  // ---- toast (flash messages) ----------------------------------------------
  const toastEl = $('#toast');
  let toastTimer = null;
  function toast(text, kind) {
    if (!toastEl) return;
    $('#toast-text').textContent = text;
    toastEl.classList.toggle('bad', kind === 'err');
    toastEl.classList.toggle('good', kind !== 'err');
    toastEl.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toastEl.hidden = true; }, kind === 'err' ? 9000 : 4500);
  }
  window.jhToast = toast;
  if (toastEl && !toastEl.hidden) {
    toastTimer = setTimeout(() => { toastEl.hidden = true; }, toastEl.classList.contains('bad') ? 9000 : 4500);
    // Drop ?msg=/&err= from the address bar so a reload does not show it again.
    try {
      const u = new URL(location.href);
      if (u.searchParams.has('msg') || u.searchParams.has('err')) {
        u.searchParams.delete('msg'); u.searchParams.delete('err');
        history.replaceState(null, '', u.pathname + (u.search || '') + u.hash);
      }
    } catch (e) {}
  }
  const toastClose = $('#toast-close');
  toastClose && toastClose.addEventListener('click', () => { toastEl.hidden = true; });

  // ---- API helper ------------------------------------------------------------
  async function api(method, path, body) {
    const r = await fetch(BASE + '/api/v1' + path, {
      method, credentials: 'same-origin',
      headers: body !== undefined ? {'Content-Type': 'application/json', 'Accept': 'application/json'} : {'Accept': 'application/json'},
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
    let data = null;
    try { data = await r.json(); } catch (e) {}
    if (!r.ok) throw new Error((data && data.detail) || ('HTTP ' + r.status));
    return data;
  }
  window.jhApi = api;

  // ---- loading states for classic forms --------------------------------------
  document.addEventListener('submit', (ev) => {
    const form = ev.target;
    if (!(form instanceof HTMLFormElement) || form.method.toLowerCase() !== 'post' || ev.defaultPrevented) return;
    const btn = ev.submitter || $('button[type=submit], button:not([type])', form);
    setTimeout(() => {  // after onsubmit confirm() handlers
      if (ev.defaultPrevented) return;
      $$('button', form).forEach((b) => { b.disabled = true; });
      if (btn) btn.classList.add('busy');
    }, 0);
  });

  // ---- quick status selects (lists, tracker cards, detail action bar) ---------
  document.addEventListener('change', async (ev) => {
    const sel = ev.target;
    if (!(sel instanceof HTMLSelectElement) || !sel.classList.contains('quick-status')) return;
    const id = sel.dataset.id, old = sel.dataset.current, status = sel.value;
    if (status === old) return;
    sel.disabled = true;
    try {
      await api('PATCH', '/jobs/' + id, {status});
      sel.dataset.current = status;
      const label = sel.options[sel.selectedIndex].textContent.trim();
      toast('Status: ' + label, 'ok');
      document.dispatchEvent(new CustomEvent('jh:status', {detail: {id, status, old}}));
      if (sel.dataset.reload === '1') setTimeout(() => location.reload(), 500);
    } catch (e) {
      sel.value = old;
      toast('Nicht gespeichert: ' + e.message, 'err');
    } finally {
      sel.disabled = false;
    }
  });

  // ---- keyboard navigation -----------------------------------------------------
  let active = -1;
  const items = () => $$('.kb-item').filter((el) => el.offsetParent !== null);
  function setActive(i) {
    const list = items();
    if (!list.length) return;
    active = Math.max(0, Math.min(i, list.length - 1));
    list.forEach((el, n) => el.classList.toggle('kb-active', n === active));
    list[active].scrollIntoView({block: 'nearest'});
  }
  function current() { const list = items(); return active >= 0 ? list[active] : null; }
  const help = $('#kbd-help');
  $('#kbd-help-btn') && $('#kbd-help-btn').addEventListener('click', () => help && help.showModal());
  const GO = {h: '/today', n: '/?view=recent', a: '/?view=auto', m: '/?view=manual', t: '/tracker', p: '/outbox'};
  let pendingG = false;
  document.addEventListener('keydown', (ev) => {
    const tag = (ev.target.tagName || '').toLowerCase();
    if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
    if (['input', 'textarea', 'select'].includes(tag) || ev.target.isContentEditable) {
      if (ev.key === 'Escape') ev.target.blur();
      return;
    }
    if (pendingG) {
      pendingG = false;
      if (GO[ev.key]) { location.href = BASE + GO[ev.key]; ev.preventDefault(); }
      return;
    }
    switch (ev.key) {
      case 'j': setActive(active + 1); break;
      case 'k': setActive(active < 0 ? 0 : active - 1); break;
      case 'o': case 'Enter': {
        const c = current(); const a = c && $('a.kb-open', c);
        if (a) { a.click(); } else return;
        break;
      }
      case 's': {
        const c = current();
        const sel = (c && $('select.quick-status', c)) || $('#status-select') || $('select.quick-status');
        if (!sel) return;
        sel.focus();
        try { sel.showPicker(); } catch (e) {}
        break;
      }
      case 'x': {
        const c = current(); const cb = c && $('input.bulk-cb', c);
        if (!cb) return;
        cb.checked = !cb.checked; cb.dispatchEvent(new Event('change', {bubbles: true}));
        break;
      }
      case '/': { const q = $('input[type=search]'); if (!q) return; q.focus(); q.select(); break; }
      case '?': if (help) help.showModal(); break;
      case 'g': pendingG = true; setTimeout(() => { pendingG = false; }, 1200); break;
      case 'Escape': {
        $$('input.bulk-cb:checked').forEach((cb) => { cb.checked = false; });
        document.dispatchEvent(new Event('jh:bulk'));
        break;
      }
      default: return;
    }
    ev.preventDefault();
  });

  // ---- sticky list filters (remembered per view in this browser) --------------
  const filters = $('form.filters');
  if (filters) {
    const view = (new URLSearchParams(location.search)).get('view') || '';
    const key = 'jh-filters:' + view;
    const params = new URLSearchParams(location.search);
    if (params.get('reset') === '1') {
      try { localStorage.removeItem(key); } catch (e) {}
    } else {
      const keys = [...params.keys()].filter((k) => !['view', 'msg', 'err'].includes(k));
      if (!keys.length) {
        let saved = null;
        try { saved = localStorage.getItem(key); } catch (e) {}
        if (saved) { location.replace(location.pathname + '?' + saved); return; }
      } else {
        const keep = new URLSearchParams();
        params.forEach((v, k) => { if (v && !['msg', 'err', 'reset'].includes(k)) keep.append(k, v); });
        try { localStorage.setItem(key, keep.toString()); } catch (e) {}
      }
    }
  }

  // ---- bulk actions (index list) --------------------------------------------------
  const bulkBar = $('#bulkbar');
  if (bulkBar) {
    const all = $('#bulk-all');
    const update = () => {
      const ids = $$('input.bulk-cb:checked').map((cb) => Number(cb.value));
      bulkBar.hidden = ids.length === 0;
      $('#bulk-count').textContent = ids.length === 1 ? '1 ausgewählt' : ids.length + ' ausgewählt';
      if (all) all.checked = ids.length > 0 && ids.length === $$('input.bulk-cb').length;
      return ids;
    };
    document.addEventListener('change', (ev) => {
      if (ev.target.classList && ev.target.classList.contains('bulk-cb')) update();
    });
    document.addEventListener('jh:bulk', update);
    all && all.addEventListener('change', () => {
      $$('input.bulk-cb').forEach((cb) => { cb.checked = all.checked; });
      update();
    });
    $$('[data-bulk]', bulkBar).forEach((btn) => btn.addEventListener('click', async () => {
      const ids = update();
      if (!ids.length) return;
      const kind = btn.dataset.bulk;
      let body = {ids};
      if (kind === 'status') {
        const st = $('#bulk-status').value;
        if (!st) { toast('Bitte einen Status wählen.', 'err'); return; }
        body.status = st;
      } else if (kind === 'zu_weit') { body.status = 'zu_weit'; }
      else if (kind === 'duplikat') {
        if (!confirm(ids.length + ' Stelle(n) als Duplikat ausblenden (Status Absage, Grund „Duplikat“)?')) return;
        body.status = 'absage'; body.close_reason = 'duplikat';
      } else if (kind === 'letters') { body.write_letters = true; }
      btn.disabled = true; btn.classList.add('busy');
      try {
        const r = await api('POST', '/jobs/bulk', body);
        const parts = [];
        if (r.updated) parts.push(r.updated + ' geändert');
        if (r.letters_started) parts.push('KI schreibt die Anschreiben im Hintergrund');
        if (r.hint) parts.push(r.hint);
        toast(parts.join(' · ') || 'Erledigt.', r.hint && !r.updated && !r.letters_started ? 'err' : 'ok');
        setTimeout(() => location.reload(), r.hint ? 1800 : 700);
      } catch (e) {
        toast('Nicht ausgeführt: ' + e.message, 'err');
      } finally { btn.disabled = false; btn.classList.remove('busy'); }
    }));
    $('#bulk-clear') && $('#bulk-clear').addEventListener('click', () => {
      $$('input.bulk-cb').forEach((cb) => { cb.checked = false; });
      update();
    });
  }

  // ---- copy buttons (data-copy="#element-id" or data-copy-text) ----------------------
  document.addEventListener('click', async (ev) => {
    const btn = ev.target.closest && ev.target.closest('[data-copy]');
    if (!btn) return;
    const src = $(btn.dataset.copy);
    const text = src ? (src.value !== undefined ? src.value : src.textContent) : '';
    try { await navigator.clipboard.writeText(text); }
    catch (e) { if (src && src.select) { src.hidden = false; src.select(); document.execCommand('copy'); } }
    const label = btn.textContent;
    btn.textContent = 'Kopiert ✓';
    setTimeout(() => { btn.textContent = label; }, 1500);
  });
})();
