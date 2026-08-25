// Inbox is intentionally non-consuming. Only its explicit acknowledgement
// button posts to the hub; selecting and opening records are both GETs.
(function () {
  'use strict';

  var api = window.PizarraApi;
  if (!api) { return; }
  var state = {loaded: false, loading: false, all: false, messages: [], selected: 0, remaining: 0};
  var ui = {
    view: document.querySelector('[data-app-view="inbox"]'),
    list: document.getElementById('inbox-list'), loading: document.getElementById('inbox-loading'),
    empty: document.getElementById('inbox-empty'), title: document.getElementById('inbox-title'),
    detail: document.getElementById('inbox-detail'), notice: document.getElementById('inbox-notice'),
    all: document.getElementById('inbox-all'), refresh: document.getElementById('inbox-refresh'),
    ack: document.getElementById('inbox-ack'), more: document.getElementById('inbox-more')
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
  function validInbox(data) {
    var seen = new Set();
    return api.object(data) && Array.isArray(data.messages) && data.messages.every(function (item) {
      if (!validHead(item) || seen.has(item.seq)) { return false; }
      seen.add(item.seq);
      return true;
    });
  }
  function notice(message, error) {
    ui.notice.textContent = message;
    ui.notice.className = 'records-notice' + (error ? ' records-notice--error' : '');
    ui.notice.hidden = false;
  }
  function clearNotice() { ui.notice.hidden = true; }
  function placeholder() {
    ui.detail.replaceChildren();
    var empty = text('div', 'records-empty');
    empty.appendChild(text('strong', '', 'Select a headline'));
    empty.appendChild(text('span', '', 'You can open the full content without acknowledging it.'));
    ui.detail.appendChild(empty);
  }
  function render() {
    ui.list.replaceChildren();
    ui.list.setAttribute('aria-busy', state.loading ? 'true' : 'false');
    ui.loading.hidden = state.loaded || !state.loading;
    ui.empty.hidden = !state.loaded || state.messages.length !== 0;
    ui.title.textContent = state.all ? 'All delivered messages' : 'Unread messages';
    // Acknowledgement is a watermark: it marks every earlier message as read.
    // Disable it in the all-messages view, which shows only a recent window.
    ui.ack.disabled = state.loading || state.all || state.messages.length === 0;
    // Show Load more only when the server confirms that more records exist.
    ui.more.hidden = !(state.remaining > 0);
    ui.more.textContent = 'Load more (' + state.remaining + ')';
    ui.more.disabled = state.loading;
    ui.ack.title = state.all
      ? 'Acknowledgement only applies to unread messages: it marks everything before them as read, while this view shows the most recent messages.'
      : 'Mark messages as read through the last message in this list.';
    state.messages.forEach(function (message) {
      var item = text('li', 'record-item');
      var button = text('button', 'record-item__button');
      var top = text('div', 'record-item__top');
      var route = text('span', 'record-item__route');
      button.type = 'button';
      button.dataset.inboxSeq = String(message.seq);
      button.setAttribute('aria-selected', message.seq === state.selected ? 'true' : 'false');
      route.appendChild(text('strong', '', message.from));
      route.appendChild(text('span', '', ' → ' + message.to));
      top.appendChild(route);
      top.appendChild(text('span', 'record-item__seq', '#' + message.seq));
      button.appendChild(top);
      button.appendChild(text('p', 'record-item__head', api.plainText(message.head)));
      if (message.cut) { button.appendChild(text('span', 'record-item__cut', 'Headline of ' + message.len + ' characters · open to read all')); }
      button.appendChild(text('div', 'record-item__meta', message.ts + (message.via ? ' · ' + message.via : '')));
      item.appendChild(button);
      ui.list.appendChild(item);
    });
  }
  // Inbox pages are non-consuming. The server returns a window and the number
  // of remaining records; acknowledgement remains a separate explicit action.
  function load(appendMore) {
    var after = 0;
    if (appendMore === true && state.messages.length) {
      after = state.messages.reduce(function (m, it) { return Math.max(m, it.seq); }, 0);
    }
    state.loading = true;
    if (appendMore !== true) { state.selected = 0; placeholder(); }
    render();
    clearNotice();
    var q = [];
    if (state.all) { q.push('all=true'); }
    if (after > 0) { q.push('after=' + encodeURIComponent(String(after))); }
    var path = '/api/inbox' + (q.length ? '?' + q.join('&') : '');
    return api.request(path).then(function (data) {
      if (!validInbox(data)) { throw new Error('The inbox response does not match the contract.'); }
      // Append additional pages; an empty page must not clear visible records.
      state.messages = (appendMore === true) ? state.messages.concat(data.messages) : data.messages.slice();
      state.remaining = api.object(data) && Number.isSafeInteger(data.more) ? data.more : 0;
      state.loaded = true;
    }).catch(function (error) {
      notice(error.message, true);
    }).finally(function () {
      state.loading = false;
      render();
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
    heading.appendChild(text('p', 'section-kicker', 'Full message · not acknowledged'));
    heading.appendChild(text('h2', '', '#' + message.seq + ' · ' + message.from + ' → ' + message.to));
    head.appendChild(heading);
    meta.appendChild(text('span', '', message.ts));
    if (message.via) { meta.appendChild(text('span', '', message.via)); }
    ui.detail.appendChild(head);
    ui.detail.appendChild(meta);
    ui.detail.appendChild(text('p', 'records-detail__text', api.plainText(message.text)));
  }
  function openMessage(seq) {
    state.selected = seq;
    render();
    return api.request('/api/message/' + encodeURIComponent(String(seq))).then(function (data) {
      if (!api.object(data) || !Array.isArray(data.full) || data.full.length > 1 ||
          (data.full.length === 1 && !validFull(data.full[0], seq))) {
        throw new Error('The full text does not match the contract.');
      }
      if (!data.full.length) {
        ui.detail.replaceChildren();
        ui.detail.appendChild(text('p', 'records-detail__warning', 'This message is no longer available in the journal. Opening it did not mark anything as read.'));
        return;
      }
      showFull(data.full[0]);
    }).catch(function (error) { notice(error.message, true); });
  }
  function acknowledge() {
    if (!state.messages.length) { return; }
    // Enforce the acknowledgement guard in logic as well as in button state.
    if (state.all) {
      notice('Turn off "all messages" before acknowledging: acknowledgement marks everything before them as read, while this view shows the most recent messages.', true);
      return;
    }
    var upto = state.messages.reduce(function (last, item) { return Math.max(last, item.seq); }, 0);
    ui.ack.disabled = true;
    clearNotice();
    return api.post('/api/inbox/ack', {upto: upto}).then(function (data) {
      if (!api.object(data) || !own(data, 'acked')) { throw new Error('The acknowledgement does not match the contract.'); }
      // Report the watermark confirmed by the server.
      var acknowledgedThrough = Number.isSafeInteger(data.acked) && data.acked > 0 ? data.acked : upto;
      notice('Acknowledged through #' + acknowledgedThrough + '. The view will refresh now.', false);
      return load();
    }).catch(function (error) {
      notice(error.message, true);
      render();
    });
  }

  ui.list.addEventListener('click', function (event) {
    var button = event.target.closest('[data-inbox-seq]');
    if (button) { openMessage(Number(button.dataset.inboxSeq)); }
  });
  // Confirm refreshes visibly even when the message set did not change.
  ui.refresh.addEventListener('click', function () {
    load().then(function () {
      var d = new Date();
      notice('Updated ' + ('0' + d.getHours()).slice(-2) + ':' +
        ('0' + d.getMinutes()).slice(-2) + ':' + ('0' + d.getSeconds()).slice(-2) +
        ' · ' + state.messages.length + ' on screen.', false);
    });
  });
  ui.more.addEventListener('click', function () { load(true); });
  ui.all.addEventListener('change', function () { state.all = ui.all.checked; load(); });
  ui.ack.addEventListener('click', acknowledge);
  window.addEventListener('pizarra:view', function (event) {
    if (event.detail.name === 'inbox' && !state.loaded && !state.loading) { load(); }
  });
  if (!ui.view.hidden) { load(); }
})();
