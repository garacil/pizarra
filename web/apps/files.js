// Exchange index. It lists the one level the server exposes, passes a
// server-supplied file path to the transfer app without inventing one, and
// offers the ONE mutation the operator asked for by hand: delete, confirmed
// by typing the name - the same pattern as the task delete in manage.js.
(function () {
  'use strict';

  var api = window.PizarraApi;
  if (!api) { return; }
  var state = {loaded: false, loading: false, root: [], team: '', files: [], filesLoading: false, filesError: ''};
  // Pending deletion, including whether the separately confirmed recursive
  // path was selected.
  var pendingDeletion = null;
  var ui = {
    view: document.querySelector('[data-app-view="files"]'),
    refresh: document.getElementById('files-refresh'), notice: document.getElementById('files-notice'),
    teams: document.getElementById('files-team-list'), teamLoading: document.getElementById('files-team-loading'),
    teamEmpty: document.getElementById('files-team-empty'), teamCount: document.getElementById('files-team-count'),
    title: document.getElementById('files-title'), path: document.getElementById('files-path'), list: document.getElementById('files-list'),
    dialog: document.getElementById('files-dialog'), form: document.getElementById('files-form'),
    dialogKicker: document.getElementById('files-dialog-kicker'), dialogTitle: document.getElementById('files-dialog-title'),
    dialogHelp: document.getElementById('files-dialog-help'), dialogWarning: document.getElementById('files-dialog-warning'),
    dialogLabel: document.getElementById('files-dialog-label'), input: document.getElementById('files-dialog-confirm'),
    dialogError: document.getElementById('files-dialog-error'),
    recursive: document.getElementById('files-dialog-recursive'), submit: document.getElementById('files-dialog-submit')
  };
  var kinds = {file: true, dir: true, link: true, special: true};

  function text(tag, className, value) {
    var node = document.createElement(tag);
    if (className) { node.className = className; }
    node.textContent = value;
    return node;
  }
  function validName(value) {
    return typeof value === 'string' && value.length > 0 && value !== '.' && value !== '..' &&
      value.indexOf('/') < 0 && value.indexOf('\\') < 0 && value.indexOf('\u0000') < 0;
  }
  function validEntry(item) {
    return api.object(item) && validName(item.name) && typeof item.kind === 'string' && kinds[item.kind] === true &&
      Number.isSafeInteger(item.bytes) && item.bytes >= 0 && typeof item.ts === 'string' &&
      // managed is optional, but must be boolean because it controls the
      // warning that the hub will restore this file.
      (!Object.prototype.hasOwnProperty.call(item, 'managed') || typeof item.managed === 'boolean');
  }
  function validEntries(data, key) {
    var names = new Set();
    return api.object(data) && Array.isArray(data[key]) && data[key].every(function (item) {
      if (!validEntry(item) || names.has(item.name)) { return false; }
      names.add(item.name);
      return true;
    });
  }
  function notice(message, error) {
    ui.notice.textContent = message;
    ui.notice.className = 'records-notice' + (error ? ' records-notice--error' : '');
    ui.notice.hidden = false;
  }
  function clearNotice() { ui.notice.hidden = true; }
  function currentTime() {
    var d = new Date();
    return ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) +
           ':' + ('0' + d.getSeconds()).slice(-2);
  }
  function bytes(value) {
    if (value < 1024) { return value + ' B'; }
    var labels = ['KiB', 'MiB', 'GiB'];
    var size = value;
    var unit = 0;
    while (size >= 1024 && unit < labels.length - 1) { size /= 1024; unit += 1; }
    return size.toLocaleString('en', {maximumFractionDigits: 1}) + ' ' + labels[unit];
  }
  function kindIcon(kind) { return {file: 'F', dir: 'D', link: '↗', special: '!'}[kind]; }
  function renderRoot() {
    ui.teams.replaceChildren();
    ui.teams.setAttribute('aria-busy', state.loading ? 'true' : 'false');
    ui.teamLoading.hidden = state.loaded || !state.loading;
    ui.teamEmpty.hidden = !state.loaded || state.root.length !== 0;
    // The displayed count is specifically the number of directories.
    ui.teamCount.textContent = state.loaded
      ? String(state.root.filter(function (e) { return e.kind === 'dir'; }).length)
      : '—';
    if (!state.loaded) { return; }
    // Group loose root entries under '.', the conventional current directory.
    var looseEntries = state.root.filter(function (e) { return e.kind !== 'dir'; });
    var displayedEntries = state.root.filter(function (e) { return e.kind === 'dir'; })
      .sort(function (a, b) { return a.name.localeCompare(b.name, 'en'); });
    // Keep the synthetic root entry first.
    if (looseEntries.length) {
      displayedEntries.unshift({name: '.', kind: 'dir', bytes: 0, ts: '', looseCount: looseEntries.length});
    }
    displayedEntries.forEach(function (entry) {
      var row = text('div', 'files-team-row');
      var button = text('button', 'files-team');
      var body = text('span', 'files-team__body');
      button.type = 'button';
      button.dataset.sharedTeam = entry.name;
      button.dataset.kind = entry.kind;
      button.setAttribute('aria-current', entry.kind === 'dir' && entry.name === state.team ? 'true' : 'false');
      button.appendChild(text('span', 'files-team__icon', kindIcon(entry.kind)));
      body.appendChild(text('strong', '', entry.name));
      // Root files are directly downloadable. Links and special entries remain
      // disabled because the index deliberately neither follows nor reads them.
      body.appendChild(text('small', '',
        entry.name === '.' ? 'Files in the root (' + entry.looseCount + ')'
          : entry.kind === 'dir' ? 'Open one level'
          : (entry.kind === 'file' ? 'Download' : 'Cannot be opened from the index')));
      button.appendChild(body);
      button.appendChild(text('small', '', entry.kind === 'file' ? bytes(entry.bytes) : entry.kind));
      if (entry.kind !== 'dir' && entry.kind !== 'file') {
        button.disabled = true;
        button.setAttribute('aria-disabled', 'true');
      }
      // Never offer deletion for synthetic '.', which represents the exchange
      // root rather than a real server entry.
      if (entry.name !== '.') {
        var delRoot = text('button', 'button button--danger-quiet', 'Delete');
        delRoot.type = 'button';
        delRoot.dataset.entryName = entry.name;
        delRoot.dataset.entryKind = entry.kind;
        delRoot.dataset.rootEntry = '1';
        row.appendChild(delRoot);
      }
      row.prepend(button);
      ui.teams.appendChild(row);
    });
  }
  function emptyList(title, body) {
    ui.list.replaceChildren();
    var empty = text('div', 'records-empty');
    empty.appendChild(text('strong', '', title));
    empty.appendChild(text('span', '', body));
    ui.list.appendChild(empty);
  }
  function renderFiles() {
    ui.title.textContent = state.team ? state.team : 'Select a directory';
    ui.path.textContent = state.team ? state.team + '/' : '—';
    if (!state.team) { emptyList('No directory selected', 'Choose a valid directory from the left column.'); return; }
    if (state.filesLoading) { emptyList('Reading ' + state.team + '…', 'The server returns one level per request.'); return; }
    // A failed read is NOT an empty directory. Counting the failure as empty
    // invents a fact nobody verified - the operator goes tidy a listing that
    // broke for another reason. The notice above carries the error; the panel
    // must not contradict it with a different story.
    if (state.filesError) { emptyList('Could not read ' + state.team, state.filesError); return; }
    if (!state.files.length) { emptyList('This directory is empty', 'No links were hidden or followed.'); return; }
    ui.list.replaceChildren();
    state.files.forEach(function (entry) {
      var row = text('article', 'file-row file-row--' + entry.kind);
      var body = text('div');
      row.appendChild(text('span', 'file-row__kind', kindIcon(entry.kind)));
      body.appendChild(text('strong', '', entry.name));
      body.appendChild(text('small', '', entry.kind === 'file' ? 'Regular file' :
        entry.kind === 'dir' ? 'Directory · not opened further' :
        entry.kind === 'link' ? 'Link · not followed' : 'Special object · not downloadable'));
      row.appendChild(body);
      row.appendChild(text('span', 'file-row__meta', (entry.kind === 'file' ? bytes(entry.bytes) + ' · ' : '') + entry.ts));
      if (entry.kind === 'file') {
        var get = text('button', 'button button--quiet', 'Prepare download');
        get.type = 'button';
        // Root file paths contain only the name; team files include the directory.
        get.dataset.downloadPath = (state.team === '.' ? '' : state.team + '/') + entry.name;
        row.appendChild(get);
      }
      // Offer deletion next to every real entry; the server remains authoritative.
      var deleteButton = text('button', 'button button--danger-quiet', 'Delete');
      deleteButton.type = 'button';
      deleteButton.dataset.entryName = entry.name;
      deleteButton.dataset.entryKind = entry.kind;
      // Preserve the server's managed marker for the confirmation warning.
      if (entry.managed === true) { deleteButton.dataset.entryManaged = '1'; }
      row.appendChild(deleteButton);
      ui.list.appendChild(row);
    });
  }
  function publishTargets() {
    window.dispatchEvent(new CustomEvent('pizarra:shared-dirs', {detail: {
      names: state.root.filter(function (entry) { return entry.kind === 'dir'; }).map(function (entry) { return entry.name; })
    }}));
  }
  function loadRoot() {
    state.loading = true;
    renderRoot();
    clearNotice();
    return api.request('/api/files').then(function (data) {
      if (!validEntries(data, 'dirs')) { throw new Error('The file index does not match the contract.'); }
      state.root = data.dirs.slice().sort(function (a, b) { return a.name.localeCompare(b.name, 'en'); });
      if (!state.root.some(function (entry) { return entry.kind === 'dir' && entry.name === state.team; })) {
        state.team = '';
        state.files = [];
      }
      state.loaded = true;
      publishTargets();
    }).catch(function (error) { notice(error.message, true); }).finally(function () {
      state.loading = false;
      renderRoot();
      renderFiles();
    });
  }
  function loadTeam(team) {
    // '.' is the root listing already returned by the server, not a team.
    if (team === '.') {
      state.team = '.';
      state.filesError = '';
      state.filesLoading = false;
      state.files = state.root.filter(function (e) { return e.kind !== 'dir'; })
        .slice().sort(function (a, b) { return a.name.localeCompare(b.name, 'en'); });
      renderRoot();
      renderFiles();
      return Promise.resolve();
    }
    if (!state.root.some(function (entry) { return entry.kind === 'dir' && entry.name === team; })) { return; }
    state.team = team;
    state.files = [];
    state.filesError = '';
    state.filesLoading = true;
    renderRoot();
    renderFiles();
    clearNotice();
    return api.request('/api/files/' + encodeURIComponent(team)).then(function (data) {
      if (!api.object(data) || data.name !== team || !validEntries(data, 'files')) {
        throw new Error('The directory contents do not match the contract.');
      }
      state.files = data.files.slice().sort(function (a, b) { return a.name.localeCompare(b.name, 'en'); });
    }).catch(function (error) {
      // keep the failure visible to renderFiles: without it, the finally
      // below would paint the empty-directory card over the error.
      state.filesError = error.message;
      notice(error.message, true);
    }).finally(function () {
      state.filesLoading = false;
      renderFiles();
    });
  }
  function openTransfer(path) {
    window.location.hash = 'transfers';
    window.dispatchEvent(new CustomEvent('pizarra:download-path', {detail: {path: path}}));
  }

  ui.teams.addEventListener('click', function (event) {
    var deleteButton = event.target.closest('[data-root-entry]');
    if (deleteButton) {
      event.stopPropagation();
      openDeleteDialog(deleteButton.dataset.entryName, deleteButton.dataset.entryKind, false, true);
      return;
    }
    var button = event.target.closest('[data-shared-team]');
    if (button && button.dataset.kind === 'dir') { loadTeam(button.dataset.sharedTeam); }
    // The server anchors a root file's bare name within the shared tree.
    if (button && button.dataset.kind === 'file') { openTransfer(button.dataset.sharedTeam); }
  });
  // Deletion is this view's only mutation and requires typing the exact name.
  function describeEntryKind(kind) {
    if (kind === 'file') { return 'a regular file'; }
    if (kind === 'dir') { return 'a directory (only if it is empty; the server reports how many entries remain otherwise)'; }
    if (kind === 'link') { return 'a LINK: the shortcut is deleted, but its target is NOT touched'; }
    return 'a special object';
  }
  function currentDirectory() { return state.team === '.' ? '.' : state.team; }
  // Use a dedicated POST so unknown write outcomes remain distinguishable.
  // Send the directory in the body because browsers normalize '/./' in URLs.
  function postDeletion(dir, body) {
    var requestBody = {dir: dir};
    Object.keys(body).forEach(function (k) { requestBody[k] = body[k]; });
    body = requestBody;
    return fetch('/api/shared/delete', {
      method: 'POST',
      headers: {'Content-Type': 'application/json', 'X-Pizarra': '1'},
      body: JSON.stringify(body)
    }).then(function (response) {
      return response.json().catch(function () { throw new Error('The server returned invalid JSON.'); })
        .then(function (payload) {
          if (!response.ok || !api.object(payload) || payload.ok !== true) {
            var message = api.object(payload) && typeof payload.error === 'string' && payload.error ?
              payload.error + (typeof payload.fix === 'string' && payload.fix ? ' · ' + payload.fix : '') :
              'The request was rejected (' + response.status + ').';
            var error = new Error(message);
            error.status = response.status;
            error.outcome = api.object(payload) && typeof payload.outcome === 'string' ? payload.outcome : '';
            throw error;
          }
          return api.object(payload) && payload.data !== undefined ? payload.data : null;
        });
    });
  }
  function reloadCurrentDirectory() {
    // Reload the directory currently being viewed.
    return state.team === '.' ? loadRoot() : loadTeam(state.team);
  }
  function showDialogError(message) {
    ui.dialogError.textContent = message;
    ui.dialogError.hidden = false;
  }
  function openDeleteDialog(name, kind, recursive, root, managed) {
    pendingDeletion = {name: name, kind: kind, dir: root ? '.' : currentDirectory(),
      recursive: Boolean(recursive), root: Boolean(root),
      // Preserve managed across the first and recursive confirmations.
      managed: managed === undefined ? Boolean(pendingDeletion && pendingDeletion.managed) : Boolean(managed)};
    ui.dialogKicker.textContent = recursive ? 'Delete with contents' : 'Permanent deletion';
    ui.dialogTitle.textContent = (recursive ? 'Delete ' : 'Delete ') + name + (recursive ? ' and all its contents' : '');
    ui.dialogHelp.textContent = 'You are about to delete ' + describeEntryKind(kind) + ' from ' +
      (root ? 'the exchange root' : (pendingDeletion.dir === '.' ? 'the exchange root' : pendingDeletion.dir + '/')) + '.' +
      (root && kind === 'dir' ? ' This is a TEAM DIRECTORY in the exchange: the location where that team leaves its shared files.' : '');
    // Warn before deleting a managed file because the hub will recreate it.
    if (recursive) {
      ui.dialogWarning.textContent = 'This deletes the ENTIRE directory and everything it contains. This cannot be undone.';
      ui.dialogWarning.hidden = false;
    } else if (pendingDeletion.managed) {
      ui.dialogWarning.textContent = 'The hub RESTORES this file when it is missing: it is the startup manual, so it will reappear.';
      ui.dialogWarning.hidden = false;
    } else {
      ui.dialogWarning.textContent = '';
      ui.dialogWarning.hidden = true;
    }
    ui.dialogLabel.textContent = recursive ?
      'Enter the directory name (' + name + ') to confirm deleting its contents' :
      'Enter the full name to confirm';
    ui.input.value = '';
    ui.dialogError.hidden = true;
    // Offer recursion only after a 409; never enable it automatically.
    ui.recursive.hidden = true;
    ui.submit.textContent = recursive ? 'Delete with contents' : 'Delete';
    ui.dialog.showModal();
  }
  function executeDeletion() {
    if (!pendingDeletion) { return; }
    var target = pendingDeletion;
    ui.submit.disabled = true;
    ui.dialogError.hidden = true;
    var body = {name: target.name};
    if (target.recursive) { body.recursive = true; }
    postDeletion(target.dir, body).then(function (data) {
      ui.dialog.close();
      notice('Deleted ' + ((data && typeof data.removed === 'string') ? data.removed : target.name) + '.', false);
      return reloadCurrentDirectory();
    }).catch(function (error) {
      if (error.status === 404) {
        // A concurrent deletion is success from this view's perspective; refresh.
        ui.dialog.close();
        notice('"' + target.name + '" was already gone (someone deleted it first); the directory has been refreshed.', false);
        reloadCurrentDirectory();
        return;
      }
      if (error.status === 409) {
        // Show the server's conflict and offer a separately confirmed recursive path.
        showDialogError(error.message);
        if (target.kind === 'dir' && !target.recursive) { ui.recursive.hidden = false; }
        return;
      }
      if (error.outcome === 'unknown') {
        showDialogError(error.message + ' · Unknown outcome: DO NOT retry; reload and compare what remains.');
        return;
      }
      showDialogError(error.message);
    }).finally(function () { ui.submit.disabled = false; });
  }
  // Some index-only hosts omit the shared dialog; keep read-only features alive.
  if (ui.dialog && ui.form && ui.recursive) {
  // Enter must submit deletion rather than select a header cancel control.
  ui.input.addEventListener('keydown', function (event) {
    if (event.key === 'Enter') {
      event.preventDefault();
      ui.form.requestSubmit(ui.submit);
    }
  });
  Array.prototype.forEach.call(ui.form.querySelectorAll('[data-files-cancel]'), function (b) {
    b.addEventListener('click', function () { ui.dialog.close(); pendingDeletion = null; });
  });
  ui.recursive.addEventListener('click', function () {
    // Reopen in recursive mode for a separate, explicit confirmation.
    if (pendingDeletion) { openDeleteDialog(pendingDeletion.name, pendingDeletion.kind, true); }
  });
  ui.form.addEventListener('submit', function (event) {
    event.preventDefault();
    // An absent submitter means confirm; cancel controls are not submit buttons.
    if (event.submitter && event.submitter.value === 'cancel') { ui.dialog.close(); pendingDeletion = null; return; }
    if (!pendingDeletion) { ui.dialog.close(); return; }
    if (ui.input.value !== pendingDeletion.name) {
      showDialogError('The name does not match.');
      return;
    }
    executeDeletion();
  });
  }
  ui.list.addEventListener('click', function (event) {
    var button = event.target.closest('[data-download-path]');
    if (button) { openTransfer(button.dataset.downloadPath); }
    var deleteButton = event.target.closest('[data-entry-name]');
    if (deleteButton) {
      openDeleteDialog(deleteButton.dataset.entryName, deleteButton.dataset.entryKind, false, false,
        deleteButton.dataset.entryManaged === '1');
    }
  });
  // Refresh both the root index and the open directory, then acknowledge it visibly.
  ui.refresh.addEventListener('click', function () {
    var openDirectory = state.team;
    Promise.resolve(loadRoot()).then(function () {
      if (openDirectory && state.root.some(function (e) { return e.kind === 'dir' && e.name === openDirectory; })) {
        return loadTeam(openDirectory);
      }
      return null;
    }).then(function () { notice('Updated ' + currentTime() + '.', false); });
  });
  window.addEventListener('pizarra:view', function (event) {
    if (event.detail.name === 'files' && !state.loaded && !state.loading) { loadRoot(); }
  });
  if (!ui.view.hidden) { loadRoot(); }
})();
