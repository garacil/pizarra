// One document, several focused tools. Navigation only changes the active
// view; it never fabricates server routes or tears down application state.
(function () {
  'use strict';

  var titles = {
    activity: 'Live activity · pizarra',
    history: 'History · pizarra',
    inbox: 'Inbox · pizarra',
    files: 'Files · pizarra',
    transfers: 'Transfers · pizarra',
    workflows: 'Workflows · pizarra',
    tasks: 'Tasks · pizarra',
    structure: 'Structure · pizarra'
  };
  var views = Array.prototype.slice.call(document.querySelectorAll('[data-app-view]'));
  var links = Array.prototype.slice.call(document.querySelectorAll('[data-nav]'));
  var helpByRoute = Object.create(null);

  function helpObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  function messageOf(payload, fallback) {
    if (helpObject(payload) && typeof payload.error === 'string' && payload.error) {
      return payload.error + (payload.outcome === 'unknown' ?
        ' · Unknown outcome: do not repeat the operation; reload and compare.' :
        (typeof payload.fix === 'string' && payload.fix ? ' · ' + payload.fix : ''));
    }
    return fallback;
  }

  // Hub messages may contain terminal SGR styling. pzweb replaces forbidden
  // control bytes with U+FFFD at the JSON boundary, so remove both the original
  // ESC form and that replacement form before rendering browser text.
  function plainText(value) {
    return String(value).replace(/(?:\u001b|\uFFFD)\[[0-?]*[ -/]*[@-~]/g, '');
  }

  // HTTP Basic credentials may disappear from fetch requests without causing
  // a navigation prompt. Surface 401s in a dismissible banner and remove it as
  // soon as a request succeeds, without blocking the still-usable interface.
  var sessionBanner = null;

  function clearSessionBanner() {
    if (sessionBanner && sessionBanner.parentNode) {
      sessionBanner.parentNode.removeChild(sessionBanner);
    }
    sessionBanner = null;
  }

  function showExpiredSession() {
    if (sessionBanner) { return; }
    sessionBanner = document.createElement('div');
    sessionBanner.setAttribute('role', 'alert');
    sessionBanner.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:9999;' +
      'background:#7a1c1c;color:#fff;font:14px/1.4 system-ui,sans-serif;' +
      'padding:.7rem 1rem;display:flex;gap:1rem;align-items:center;' +
      'justify-content:center;flex-wrap:wrap';
    var message = document.createElement('span');
    message.textContent = 'Your session has expired: the browser stopped sending your ' +
      'credentials, so the data cannot be loaded.';
    var signInButton = document.createElement('button');
    signInButton.type = 'button';
    signInButton.textContent = 'Sign in again';
    signInButton.style.cssText = 'font:inherit;padding:.3rem .9rem;cursor:pointer';
    // A user-triggered navigation lets the browser request credentials again.
    // Never reload automatically, which could create an authentication loop.
    signInButton.addEventListener('click', function () { window.location.reload(); });
    var closeButton = document.createElement('button');
    closeButton.type = 'button';
    closeButton.textContent = 'Close';
    closeButton.style.cssText = 'font:inherit;padding:.3rem .9rem;cursor:pointer';
    closeButton.addEventListener('click', clearSessionBanner);
    sessionBanner.appendChild(message);
    sessionBanner.appendChild(signInButton);
    sessionBanner.appendChild(closeButton);
    document.body.appendChild(sessionBanner);
  }

  function request(path, options) {
    return fetch(path, options || {}).then(function (response) {
      if (response.status === 401) {
        showExpiredSession();
        throw new Error('Your session has expired. Sign in again.');
      }
      clearSessionBanner();
      return response.json().catch(function () {
        throw new Error('The server returned invalid JSON.');
      }).then(function (payload) {
        if (!response.ok || !helpObject(payload) || payload.ok !== true) {
          throw new Error(messageOf(payload,
            'The request was rejected (' + response.status + ').'));
        }
        if (!Object.prototype.hasOwnProperty.call(payload, 'data')) {
          throw new Error('The response does not contain the contract\'s data field.');
        }
        return payload.data;
      });
    });
  }

  window.PizarraApi = {
    object: helpObject,
    plainText: plainText,
    request: request,
    post: function (path, body, signal) {
      return request(path, {
        method: 'POST',
        headers: {'Content-Type': 'application/json', 'X-Pizarra': '1'},
        body: JSON.stringify(body),
        signal: signal
      });
    }
  };

  window.PizarraHelp = {
    forRoute: function (route, fallback) {
      var item = helpByRoute[route];
      if (!item) { return {text: fallback || '', warning: ''}; }
      return {text: item.que + ' ' + item.pasa, warning: item.ojo || ''};
    }
  };

  // These Spanish property names are part of the established /api/help wire
  // contract. Keep them exact while all internal identifiers remain English.
  fetch('/api/help').then(function (response) {
    if (!response.ok) { throw new Error('help unavailable'); }
    return response.json();
  }).then(function (payload) {
    var list = helpObject(payload) && payload.ok === true && helpObject(payload.data) ? payload.data.ayuda : null;
    var nextHelp = Object.create(null);
    if (!Array.isArray(list)) { throw new Error('help shape'); }
    list.forEach(function (item) {
      if (!helpObject(item) || typeof item.ruta !== 'string' || typeof item.que !== 'string' ||
          typeof item.pasa !== 'string' || !item.ruta || !item.que || !item.pasa ||
          Object.keys(item).some(function (key) { return ['ruta', 'que', 'pasa', 'ojo'].indexOf(key) < 0; }) ||
          (Object.prototype.hasOwnProperty.call(item, 'ojo') && typeof item.ojo !== 'string') || nextHelp[item.ruta]) {
        throw new Error('help entry shape');
      }
      nextHelp[item.ruta] = item;
    });
    helpByRoute = nextHelp;
    window.dispatchEvent(new CustomEvent('pizarra:help'));
  }).catch(function () {
    /* Existing dialog explanations are the deliberate offline fallback. */
  });

  function selectedView() {
    var name = window.location.hash.replace(/^#/, '');
    return Object.prototype.hasOwnProperty.call(titles, name) ? name : 'activity';
  }

  function show(name) {
    views.forEach(function (view) {
      view.hidden = view.dataset.appView !== name;
    });
    links.forEach(function (link) {
      var active = link.dataset.nav === name;
      link.classList.toggle('nav-item--active', active);
      if (active) {
        link.setAttribute('aria-current', 'page');
      } else {
        link.removeAttribute('aria-current');
      }
    });
    document.title = titles[name];
    window.dispatchEvent(new CustomEvent('pizarra:view', {detail: {name: name}}));
  }

  window.addEventListener('hashchange', function () {
    show(selectedView());
  });

  show(selectedView());
})();
