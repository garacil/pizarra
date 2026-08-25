// The feed is the first small pizarra app: one hub-authorized SSE stream, rendered
// without HTML strings. Every value received from the hub reaches the DOM only
// through textContent after its contract shape has been checked.
(function () {
  'use strict';

  var MAX_ROWS = 300;
  var MAX_SEEN = 1200;
  var allowedGapReasons = {
    queue_overflow: true,
    replay_overflow: true,
    history_unavailable: true,
    cursor_ahead: true
  };

  var state = {
    total: 0,
    incoming: 0,
    outgoing: 0,
    other: 0,
    lastSeq: null,
    filter: 'all',
    seen: new Set(),
    seenOrder: [],
    source: null,
    stopped: false,
    attempts: 0,
    retryTimer: null,
    openWatchdog: null
  };

  var ui = {
    connection: document.getElementById('connection'),
    connectionTitle: document.getElementById('connection-title'),
    connectionDetail: document.getElementById('connection-detail'),
    total: document.getElementById('metric-total'),
    incoming: document.getElementById('metric-in'),
    outgoing: document.getElementById('metric-out'),
    other: document.getElementById('metric-other'),
    seq: document.getElementById('metric-seq'),
    allCount: document.getElementById('filter-all-count'),
    inCount: document.getElementById('filter-in-count'),
    outCount: document.getElementById('filter-out-count'),
    otherCount: document.getElementById('filter-other-count'),
    feed: document.getElementById('feed'),
    empty: document.getElementById('empty'),
    emptyTitle: document.getElementById('empty-title'),
    emptyBody: document.getElementById('empty-body'),
    alert: document.getElementById('feed-alert'),
    alertTitle: document.getElementById('alert-title'),
    alertBody: document.getElementById('alert-body'),
    reload: document.getElementById('reload'),
    filters: Array.prototype.slice.call(document.querySelectorAll('[data-filter]'))
  };

  function setConnection(kind, title, detail) {
    ui.connection.className = 'connection connection--' + kind;
    ui.connectionTitle.textContent = title;
    ui.connectionDetail.textContent = detail;
  }

  function showAlert(title, body, reloadable) {
    ui.alertTitle.textContent = title;
    ui.alertBody.textContent = body;
    ui.reload.hidden = !reloadable;
    ui.alert.hidden = false;
  }

  function hideAlert() {
    ui.alert.hidden = true;
    ui.reload.hidden = true;
  }

  function updateStats() {
    ui.total.textContent = String(state.total);
    ui.incoming.textContent = String(state.incoming);
    ui.outgoing.textContent = String(state.outgoing);
    ui.other.textContent = String(state.other);
    ui.seq.textContent = state.lastSeq === null ? '—' : String(state.lastSeq);
    ui.allCount.textContent = String(state.total);
    ui.inCount.textContent = String(state.incoming);
    ui.outCount.textContent = String(state.outgoing);
    ui.otherCount.textContent = String(state.other);
  }

  function isObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  function parseEvent(event, expected) {
    var value;
    try {
      value = JSON.parse(event.data);
    } catch (error) {
      return null;
    }
    if (!isObject(value) || value.ev !== expected) {
      return null;
    }
    return value;
  }

  function validMessage(value) {
    return Number.isSafeInteger(value.seq) && value.seq > 0 &&
      typeof value.ts === 'string' &&
      typeof value.from === 'string' && value.from.length > 0 &&
      typeof value.to === 'string' && value.to.length > 0 &&
      typeof value.text === 'string' &&
      (value.dir === 'in' || value.dir === 'out' || value.dir === 'other');
  }

  function remember(seq) {
    if (state.seen.has(seq)) {
      return false;
    }
    state.seen.add(seq);
    state.seenOrder.push(seq);
    if (state.seenOrder.length > MAX_SEEN) {
      state.seen.delete(state.seenOrder.shift());
    }
    return true;
  }

  function makeText(tag, className, text) {
    var node = document.createElement(tag);
    if (className) {
      node.className = className;
    }
    node.textContent = text;
    return node;
  }

  function rowVisible(row) {
    return state.filter === 'all' || row.dataset.direction === state.filter;
  }

  function updateEmptyState() {
    var rows = Array.prototype.slice.call(ui.feed.children);
    var visible = rows.some(rowVisible);
    ui.empty.hidden = visible;
    if (visible) {
      return;
    }
    if (state.total === 0) {
      ui.emptyTitle.textContent = 'Waiting for activity';
      ui.emptyBody.textContent = 'New messages will appear here without reloading the page.';
    } else {
      ui.emptyTitle.textContent = 'No messages match this filter';
      ui.emptyBody.textContent = 'Change the direction to view this session\'s activity again.';
    }
  }

  function applyFilter(filter) {
    state.filter = filter;
    ui.filters.forEach(function (button) {
      var active = button.dataset.filter === filter;
      button.classList.toggle('filter--active', active);
      button.setAttribute('aria-pressed', active ? 'true' : 'false');
    });
    Array.prototype.forEach.call(ui.feed.children, function (row) {
      row.hidden = !rowVisible(row);
    });
    updateEmptyState();
  }

  function renderMessage(value) {
    var row = document.createElement('li');
    var directionMeta = {
      in: {icon: '↙', label: 'Incoming'},
      out: {icon: '↗', label: 'Outgoing'},
      other: {icon: '↔', label: 'Between other teams'}
    }[value.dir];
    var direction = makeText('span', 'feed-item__direction', directionMeta.icon);
    var content = document.createElement('div');
    var top = document.createElement('div');
    var route = document.createElement('div');
    var meta = makeText('span', 'feed-item__meta', value.ts + '  ·  #' + value.seq);
    var body = makeText('p', 'feed-item__text', window.PizarraApi.plainText(value.text));

    row.className = 'feed-item feed-item--' + value.dir;
    row.dataset.direction = value.dir;
    direction.setAttribute('aria-label', directionMeta.label);
    top.className = 'feed-item__top';
    route.className = 'feed-item__route';
    route.appendChild(makeText('strong', '', value.from));
    route.appendChild(makeText('span', 'feed-item__arrow', '→'));
    route.appendChild(makeText('strong', '', value.to));
    top.appendChild(route);
    top.appendChild(meta);
    content.appendChild(top);
    content.appendChild(body);
    row.appendChild(direction);
    row.appendChild(content);
    row.hidden = !rowVisible(row);
    ui.feed.prepend(row);

    while (ui.feed.children.length > MAX_ROWS) {
      ui.feed.lastElementChild.remove();
    }
  }

  function stopForProtocol(reason) {
    state.stopped = true;
    if (state.source) {
      state.source.close();
    }
    setConnection('error', 'Channel stopped', 'The response does not match the feed contract.');
    showAlert('This view cannot be verified', reason, true);
  }

  function onMessage(event) {
    var value = parseEvent(event, 'msg');
    if (!value || !validMessage(value)) {
      stopForProtocol('A message arrived in an unexpected format. Reload to open a fresh view.');
      return;
    }
    if (!remember(value.seq)) {
      return;
    }
    state.total += 1;
    state.lastSeq = value.seq;
    if (value.dir === 'in') {
      state.incoming += 1;
    } else if (value.dir === 'out') {
      state.outgoing += 1;
    } else {
      state.other += 1;
    }
    renderMessage(value);
    updateStats();
    updateEmptyState();
  }

  function onGap(event) {
    var value = parseEvent(event, 'gap');
    if (!value || !Number.isSafeInteger(value.after) || value.after < 0 ||
        !allowedGapReasons[value.reason]) {
      stopForProtocol('The loss warning does not match the contract. Reload to start over.');
      return;
    }
    state.stopped = true;
    state.source.close();
    setConnection('warning', 'Incomplete view', 'The hub cannot verify the entire range.');
    showAlert(
      'Visible messages are missing',
      'The channel reported a loss (' + value.reason + ') after sequence ' + value.after + '. Reload before continuing.',
      true
    );
  }

  function onBye(event) {
    var value = parseEvent(event, 'bye');
    if (!value || typeof value.reason !== 'string') {
      stopForProtocol('The channel closure does not match the contract. Reload to start over.');
      return;
    }
    if (value.reason === 'closing') {
      setConnection('connecting', 'Reconnecting', 'The server closed the channel and the browser will reopen it.');
      return;
    }
    stopForProtocol('The server closed the channel: ' + value.reason + '. Reload to try again.');
  }

  function connect() {
    // Each handler belongs to the EventSource that emitted its event. Close any
    // previous source before opening another so stale events cannot move the
    // current cursor and abandoned streams cannot exhaust browser connections.
    if (state.source) { state.source.close(); state.source = null; }
    // Manual reconnects do not carry Last-Event-ID, so pass the last durable
    // sequence explicitly to avoid silently losing events between streams.
    var stream = new EventSource('/api/feed' +
      (Number.isSafeInteger(state.lastSeq) && state.lastSeq >= 0 ?
        '?since=' + encodeURIComponent(String(state.lastSeq)) : ''));
    state.source = stream;
    function isCurrentStream() { return stream === state.source && !state.stopped; }
    // If open never arrives, close this source and retry with visible backoff
    // instead of leaving the initial connection status on screen indefinitely.
    if (state.openWatchdog) { window.clearTimeout(state.openWatchdog); }
    state.openWatchdog = window.setTimeout(function () {
      if (state.stopped || stream !== state.source) { return; }
      if (stream.readyState === EventSource.OPEN) { return; }
      stream.close();
      state.source = null;
      state.attempts += 1;
      var delay = Math.min(30000, 1000 * Math.pow(2, state.attempts - 1));
      setConnection('connecting', 'Reconnecting',
        'The channel did not respond within 4 seconds; reopening in ' + Math.round(delay / 1000) +
        ' seconds (attempt ' + state.attempts + ').');
      if (state.retryTimer) { window.clearTimeout(state.retryTimer); }
      state.retryTimer = window.setTimeout(function () {
        state.retryTimer = null;
        if (!state.stopped) { connect(); }
      }, delay);
    }, 4000);
    stream.addEventListener('open', function () {
      if (isCurrentStream()) {
        if (state.openWatchdog) { window.clearTimeout(state.openWatchdog); state.openWatchdog = null; }
        state.attempts = 0;
        hideAlert();
        setConnection('live', 'Live', 'Channel connected and following new messages.');
      }
    });
    stream.addEventListener('message', function (ev) { if (isCurrentStream()) { onMessage(ev); } });
    stream.addEventListener('gap', function (ev) { if (isCurrentStream()) { onGap(ev); } });
    stream.addEventListener('bye', function (ev) { if (isCurrentStream()) { onBye(ev); } });
    // EventSource retries an interrupted open stream, but does not retry a
    // terminally CLOSED source. Distinguish those states and reopen CLOSED
    // sources here with exponential backoff and a visible attempt count.
    stream.addEventListener('error', function () {
      // A stale source must never alter the current source.
      if (stream !== state.source) { stream.close(); return; }
      if (state.stopped) { return; }
      if (stream.readyState === EventSource.CONNECTING) {
        setConnection('connecting', 'Reconnecting', 'The channel was interrupted; the browser is retrying.');
        return;
      }
      stream.close();
      state.source = null;
      state.attempts += 1;
      var delay = Math.min(30000, 1000 * Math.pow(2, state.attempts - 1));
      setConnection('connecting', 'Reconnecting',
        'The browser closed the channel and will not retry it; reopening in ' +
        Math.round(delay / 1000) + ' seconds (attempt ' + state.attempts + ').' +
        (state.attempts >= 5 ? ' If it does not return, reload the page.' : ''));
      if (state.retryTimer) { window.clearTimeout(state.retryTimer); }
      state.retryTimer = window.setTimeout(function () {
        state.retryTimer = null;
        if (!state.stopped) { connect(); }
      }, delay);
    });
  }

  ui.filters.forEach(function (button) {
    button.addEventListener('click', function () {
      applyFilter(button.dataset.filter);
    });
  });
  ui.reload.addEventListener('click', function () {
    window.location.reload();
  });
  window.addEventListener('pagehide', function () {
    // Cancel pending reconnects when the page is leaving.
    if (state.retryTimer) {
      window.clearTimeout(state.retryTimer);
      state.retryTimer = null;
    }
    if (state.openWatchdog) {
      window.clearTimeout(state.openWatchdog);
      state.openWatchdog = null;
    }
    if (state.source) {
      state.source.close();
    }
  });

  updateStats();
  updateEmptyState();
  // Open the permanent stream only after the page resources have loaded so it
  // cannot consume a connection slot needed by the remaining application scripts.
  if (document.readyState === 'complete') {
    connect();
  } else {
    setConnection('connecting', 'Waiting for the page to load',
      'The live channel will open when the page finishes loading, or in a few seconds.');
    // Deliberately do not use a timeout here: an open SSE resource can itself
    // delay load, so opening it early can deadlock the condition it waits for.
    window.addEventListener('load', function () {
      if (!state.stopped) { connect(); }
    });
  }
})();
