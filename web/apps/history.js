// Durable message history. The list deliberately receives only the contractual
// headline; opening one record is the separate, explicit full-message request.
(function () {
  'use strict';

  var api = window.PizarraApi;
  if (!api) { return; }
  var state = {loaded: false, loading: false, latest: false, cursor: 0, messages: [], selected: 0};
  var ui = {
    view: document.querySelector('[data-app-view="history"]'),
    list: document.getElementById('history-list'), loading: document.getElementById('history-loading'),
    empty: document.getElementById('history-empty'), title: document.getElementById('history-title'),
    count: document.getElementById('history-count'), detail: document.getElementById('history-detail'),
    limit: document.getElementById('history-limit'), next: document.getElementById('history-next'),
    latest: document.getElementById('history-latest'), notice: document.getElementById('history-notice')
  };

  function own(value, key) { return Object.prototype.hasOwnProperty.call(value, key); }
  function text(tag, className, value) {
    var node = document.createElement(tag);
    if (className) { node.className = className; }
    node.textContent = value;
    return node;
  }
  function validHead(item) {
    return api.object(item) && Number.isSafeInteger(item.seq) && item.seq > 0 &&
      typeof item.ts === 'string' && typeof item.from === 'string' && item.from.length > 0 &&
      typeof item.to === 'string' && item.to.length > 0 && typeof item.head === 'string' &&
      Number.isSafeInteger(item.len) && item.len >= 0 && typeof item.cut === 'boolean' &&
      (!own(item, 'via') || typeof item.via === 'string');
  }
  function validHeads(data) {
    var seen = new Set();
    return api.object(data) && Array.isArray(data.messages) && data.messages.every(function (item) {
      if (!validHead(item) || seen.has(item.seq)) { return false; }
      seen.add(item.seq);
      return true;
    });
  }
  function showNotice(message, error) {
    ui.notice.textContent = message;
    ui.notice.className = 'records-notice' + (error ? ' records-notice--error' : '');
    ui.notice.hidden = false;
  }
  function clearNotice() { ui.notice.hidden = true; }
  function renderDetailPlaceholder() {
    ui.detail.replaceChildren();
    var empty = text('div', 'records-empty');
    empty.appendChild(text('strong', '', 'Select a headline'));
    empty.appendChild(text('span', '', 'The full text is requested only when you open it.'));
    ui.detail.appendChild(empty);
  }
  function renderList() {
    ui.list.replaceChildren();
    ui.list.setAttribute('aria-busy', state.loading ? 'true' : 'false');
    ui.loading.hidden = state.loaded || !state.loading;
    ui.empty.hidden = !state.loaded || state.messages.length !== 0;
    ui.count.textContent = state.loaded ? String(state.messages.length) : '—';
    if (!state.loaded) { return; }
    state.messages.forEach(function (message) {
      var item = text('li', 'record-item');
      var button = text('button', 'record-item__button');
      var top = text('div', 'record-item__top');
      var route = text('span', 'record-item__route');
      var meta = text('div', 'record-item__meta', message.ts + (message.via ? ' · ' + message.via : ''));
      var head = text('p', 'record-item__head', api.plainText(message.head));
      button.type = 'button';
      button.dataset.historySeq = String(message.seq);
      button.setAttribute('aria-selected', message.seq === state.selected ? 'true' : 'false');
      route.appendChild(text('strong', '', message.from));
      route.appendChild(text('span', '', ' → ' + message.to));
      top.appendChild(route);
      top.appendChild(text('span', 'record-item__seq', '#' + message.seq));
      button.appendChild(top);
      button.appendChild(head);
      if (message.cut) {
        button.appendChild(text('span', 'record-item__cut', 'Headline of ' + message.len + ' characters · open to read all'));
      }
      button.appendChild(meta);
      item.appendChild(button);
      ui.list.appendChild(item);
    });
  }
  function renderWindowTitle() {
    if (!state.loaded) { ui.title.textContent = 'Preparing the journal…'; return; }
    if (state.latest) {
      ui.title.textContent = 'Latest ' + ui.limit.value + ' messages';
    } else if (state.messages.length) {
      ui.title.textContent = 'Page after #' + state.cursor;
    } else {
      ui.title.textContent = 'No messages after #' + state.cursor;
    }
  }
  function load(options) {
    var latest = options && options.latest === true;
    var cursor = latest ? -1 : (options && Number.isSafeInteger(options.cursor) ? options.cursor : state.cursor);
    var limit = Number(ui.limit.value);
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 200) { return Promise.reject(new Error('The page size is invalid.')); }
    state.loading = true;
    state.selected = 0;
    renderDetailPlaceholder();
    renderList();
    clearNotice();
    var query = '?limit=' + encodeURIComponent(String(limit));
    if (cursor >= 0) { query += '&since=' + encodeURIComponent(String(cursor)); }
    return api.request('/api/messages' + query).then(function (data) {
      if (!validHeads(data)) { throw new Error('The history page does not match the contract.'); }
      state.messages = data.messages.slice();
      state.cursor = cursor >= 0 ? cursor : (state.messages.length ? state.messages[0].seq : 0);
      state.latest = latest;
      state.loaded = true;
    }).catch(function (error) {
      showNotice(error.message, true);
    }).finally(function () {
      state.loading = false;
      renderWindowTitle();
      renderList();
    });
  }
  function validFull(item, seq) {
    return api.object(item) && item.seq === seq && typeof item.ts === 'string' &&
      typeof item.from === 'string' && typeof item.to === 'string' && typeof item.text === 'string' &&
      (!own(item, 'via') || typeof item.via === 'string');
  }
  function showFull(message) {
    ui.detail.replaceChildren();
    var head = text('div', 'records-detail__head');
    var heading = text('div');
    var meta = text('div', 'records-detail__meta');
    heading.appendChild(text('p', 'section-kicker', 'Full message'));
    heading.appendChild(text('h2', '', '#' + message.seq + ' · ' + message.from + ' → ' + message.to));
    meta.appendChild(text('span', '', message.ts));
    if (message.via) { meta.appendChild(text('span', '', message.via)); }
    ui.detail.appendChild(head);
    head.appendChild(heading);
    ui.detail.appendChild(meta);
    ui.detail.appendChild(text('p', 'records-detail__text', api.plainText(message.text)));
  }
  function openMessage(seq) {
    state.selected = seq;
    renderList();
    return api.request('/api/message/' + encodeURIComponent(String(seq))).then(function (data) {
      if (!api.object(data) || !Array.isArray(data.full) || data.full.length > 1 ||
          (data.full.length === 1 && !validFull(data.full[0], seq))) {
        throw new Error('The full text does not match the contract.');
      }
      if (data.full.length === 0) {
        ui.detail.replaceChildren();
        ui.detail.appendChild(text('p', 'records-detail__warning', 'This message is no longer available in the journal. The headline remains the latest confirmed information.'));
        return;
      }
      showFull(data.full[0]);
    }).catch(function (error) {
      showNotice(error.message, true);
    });
  }

  ui.list.addEventListener('click', function (event) {
    var button = event.target.closest('[data-history-seq]');
    if (button) { openMessage(Number(button.dataset.historySeq)); }
  });
  ui.next.addEventListener('click', function () {
    if (state.messages.length) { load({cursor: state.messages[state.messages.length - 1].seq}); }
  });
  ui.latest.addEventListener('click', function () { load({latest: true}); });
  ui.limit.addEventListener('change', function () { load({cursor: state.latest ? undefined : state.cursor, latest: state.latest}); });
  window.addEventListener('pizarra:view', function (event) {
    if (event.detail.name === 'history' && !state.loaded && !state.loading) { load({cursor: 0}); }
  });
  if (!ui.view.hidden) { load({cursor: 0}); }
})();
