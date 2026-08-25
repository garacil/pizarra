// Task and registry management for the same visual application shell.
// All untrusted values become text nodes; HTTP shapes are validated before use.
(function () {
  'use strict';

  var taskState = {loaded: false, loading: false, filter: 'open', team: '', search: '', tasks: [], selected: 0,
    detailId: 0, detailError: '', subtasks: []};
  // Load each registry only when its tab is viewed. Independent status keeps a
  // failure in one registry from hiding successfully loaded registries.
  var registryState = {kind: 'teams', search: '', teams: [], groups: [], projects: [], apps: [],
    have: {}, loading: {}, error: {}};
  var teamsCache = [];
  var dialogAction = null;
  var dialogHelp = {route: '', fallback: ''};

  var dialog = {
    node: document.getElementById('manage-dialog'), form: document.getElementById('manage-form'),
    kicker: document.getElementById('manage-dialog-kicker'), title: document.getElementById('manage-dialog-title'),
    help: document.getElementById('manage-dialog-help'), warning: document.getElementById('manage-dialog-warning'),
    fields: document.getElementById('manage-form-fields'),
    error: document.getElementById('manage-form-error'), submit: document.getElementById('manage-submit')
  };
  var taskUi = {
    view: document.querySelector('[data-app-view="tasks"]'), list: document.getElementById('task-list'),
    detail: document.getElementById('task-detail'), loading: document.getElementById('task-loading'),
    empty: document.getElementById('task-empty'),
    count: document.getElementById('task-count'), search: document.getElementById('task-search'),
    team: document.getElementById('task-team-filter'), notice: document.querySelector('[data-tasks-notice]')
  };
  var registryUi = {
    view: document.querySelector('[data-app-view="structure"]'), grid: document.getElementById('registry-grid'),
    loading: document.getElementById('registry-loading'), empty: document.getElementById('registry-empty'),
    search: document.getElementById('registry-search'),
    title: document.getElementById('registry-title'), kicker: document.getElementById('registry-kicker'),
    help: document.getElementById('registry-help'), notice: document.querySelector('[data-registry-notice]')
  };

  function object(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
  function own(value, key) { return Object.prototype.hasOwnProperty.call(value, key); }
  function node(tag, className, text) {
    var result = document.createElement(tag);
    if (className) { result.className = className; }
    if (text !== undefined) { result.textContent = text; }
    return result;
  }
  function pathPart(value) { return encodeURIComponent(value); }
  function messageOf(payload, fallback) {
    if (object(payload) && typeof payload.error === 'string' && payload.error) {
      return payload.error + (payload.outcome === 'unknown' ?
        ' · Unknown outcome: DO NOT repeat the operation; reload and compare.' :
        (typeof payload.fix === 'string' && payload.fix ? ' · ' + payload.fix : ''));
    }
    return fallback;
  }
  function request(path, options) {
    return fetch(path, options || {}).then(function (response) {
      return response.json().catch(function () { throw new Error('The server returned invalid JSON.'); })
        .then(function (payload) {
          if (!response.ok || !object(payload) || payload.ok !== true) {
            var error = new Error(messageOf(payload, 'The request was rejected (' + response.status + ').'));
            error.outcome = object(payload) && typeof payload.outcome === 'string' ? payload.outcome : '';
            throw error;
          }
          if (!own(payload, 'data')) { throw new Error('The response does not contain data.'); }
          return {data: payload.data, outcome: payload.outcome || 'applied', fix: payload.fix || ''};
        });
    });
  }
  function post(path, body) {
    return request(path, {method: 'POST', headers: {'Content-Type': 'application/json', 'X-Pizarra': '1'}, body: JSON.stringify(body)});
  }
  function notice(target, message, error) {
    target.textContent = message;
    target.className = 'manage-notice' + (error ? ' manage-notice--error' : '');
    target.hidden = false;
  }

  function inputField(spec) {
    var label = node('label', 'editor-field');
    var control;
    label.appendChild(node('span', '', spec.label));
    if (spec.type === 'select') {
      control = document.createElement('select');
      (spec.options || []).forEach(function (option) {
        var item = document.createElement('option');
        item.value = typeof option === 'string' ? option : option.value;
        item.textContent = typeof option === 'string' ? option : option.label;
        item.selected = item.value === String(spec.value === undefined ? '' : spec.value);
        control.appendChild(item);
      });
    } else if (spec.type === 'textarea') {
      control = document.createElement('textarea');
      control.value = spec.value || '';
    } else {
      control = document.createElement('input');
      control.type = spec.type || 'text';
      control.value = spec.value === undefined ? '' : String(spec.value);
    }
    control.name = spec.name;
    control.required = Boolean(spec.required);
    if (spec.maxLength) { control.maxLength = spec.maxLength; }
    if (spec.placeholder) { control.placeholder = spec.placeholder; }
    label.appendChild(control);
    if (spec.help) { label.appendChild(node('small', '', spec.help)); }
    return label;
  }
  function setDialogHelp(route, fallback) {
    var help = window.PizarraHelp ? window.PizarraHelp.forRoute(route || '', fallback || '') : {text: fallback || '', warning: ''};
    dialogHelp = {route: route || '', fallback: fallback || ''};
    dialog.help.textContent = help.text;
    dialog.warning.textContent = help.warning ? 'Warning: ' + help.warning : '';
    dialog.warning.hidden = !help.warning;
  }
  function openDialog(config) {
    dialogAction = config.action;
    dialog.kicker.textContent = config.kicker || 'Manage';
    dialog.title.textContent = config.title;
    setDialogHelp(config.helpRoute || '', config.help || '');
    dialog.submit.textContent = config.submit || 'Save';
    dialog.submit.className = 'button ' + (config.danger ? 'button--danger-quiet' : 'button--primary');
    dialog.fields.replaceChildren();
    (config.fields || []).forEach(function (spec) { dialog.fields.appendChild(inputField(spec)); });
    dialog.error.hidden = true;
    dialog.node.showModal();
  }
  function replaceDialogField(spec) {
    var current = dialog.form.elements.namedItem(spec.name);
    var replacement;
    if (!current) { return null; }
    replacement = inputField(spec);
    current.closest('.editor-field').replaceWith(replacement);
    return dialog.form.elements.namedItem(spec.name);
  }
  function formValues() {
    var values = {};
    new FormData(dialog.form).forEach(function (value, key) { values[key] = String(value); });
    return values;
  }
  function mutate(path, body, onSuccess, targetNotice) {
    dialog.submit.disabled = true;
    dialog.error.hidden = true;
    return post(path, body).then(function (result) {
      dialog.node.close();
      if (result.outcome === 'applied_stale') {
        notice(targetNotice, result.fix || 'Change applied; refresh the view.', false);
      } else {
        notice(targetNotice, 'Change applied and confirmed by the hub.', false);
      }
      return onSuccess(result);
    }).catch(function (error) {
      var reconcile = Promise.resolve();
      /* Unknown means the write may have happened: read back, never retry. */
      if (error.outcome === 'unknown' && path.indexOf('/api/task') === 0) {
        reconcile = loadTasks(true);
      } else if (error.outcome === 'unknown' && path.indexOf('/api/message') !== 0) {
        reconcile = loadRegistries(true);
      }
      return reconcile.then(function () {
        var compared = '';
        if (error.outcome === 'unknown' && path.indexOf('/api/task') === 0) {
          compared = ' · The view was reloaded so you can compare the actual state.';
        } else if (error.outcome === 'unknown' && path.indexOf('/api/message') !== 0) {
          /* Registry cards intentionally omit several editable values (team
             prompts, app repository/detail and the manual body). Reloading the
             cards is useful but cannot truthfully be called a comparison. */
          compared = ' · The visible list was reloaded. DO NOT repeat the operation; reopen the record or manual and compare the value returned by the hub.';
        }
        dialog.error.textContent = error.message + compared;
        dialog.error.hidden = false;
      }, function (reloadError) {
        dialog.error.textContent = error.message + ' · Could not reload for comparison: ' + reloadError.message;
        dialog.error.hidden = false;
      });
    }).finally(function () { dialog.submit.disabled = false; });
  }

  function validNote(value) {
    return object(value) && typeof value.ts === 'string' && typeof value.by === 'string' && typeof value.text === 'string';
  }
  // The task API retains `hito` as its established milestone wire key.
  // Task lists contain only notes_count; full task records contain note bodies.
  // Keep these shapes separate and reject mixed representations.
  function validTaskRow(value) {
    return object(value) && Number.isSafeInteger(value.id) && value.id > 0 &&
      typeof value.title === 'string' && typeof value.team === 'string' && typeof value.state === 'string' &&
      typeof value.hito === 'string' && Number.isSafeInteger(value.parent) && typeof value.wf_name === 'string' &&
      Number.isSafeInteger(value.wf_step_uid) && typeof value.created === 'string' && typeof value.closed === 'string' &&
      Number.isSafeInteger(value.notes_count) && value.notes_count >= 0 && !own(value, 'notes') &&
      Array.isArray(value.depends) && value.depends.every(Number.isSafeInteger);
  }
  // Only the task detail endpoint returns note bodies.
  function validTaskDetail(value) {
    return object(value) && Number.isSafeInteger(value.id) && value.id > 0 &&
      typeof value.title === 'string' && typeof value.team === 'string' && typeof value.state === 'string' &&
      typeof value.hito === 'string' && Number.isSafeInteger(value.parent) && typeof value.wf_name === 'string' &&
      Number.isSafeInteger(value.wf_step_uid) && typeof value.created === 'string' && typeof value.closed === 'string' &&
      Array.isArray(value.notes) && value.notes.every(validNote) && Array.isArray(value.depends) &&
      value.depends.every(Number.isSafeInteger);
  }
  // Creation may return either contractual task representation.
  function validTask(value) { return validTaskDetail(value) || validTaskRow(value); }
  // Count notes from whichever contractual representation is present.
  function notesCountOf(task) {
    if (Number.isSafeInteger(task.notes_count)) { return task.notes_count; }
    if (Array.isArray(task.notes)) { return task.notes.length; }
    return 0;
  }
  function stateLabel(value) {
    var labels = {open: 'Open', done: 'Done', waiting: 'Waiting', superseded: 'Superseded', cancelled: 'Canceled'};
    return labels[value.toLocaleLowerCase('en')] || value;
  }
  function taskMatches(task) {
    var q = taskState.search.toLocaleLowerCase('en');
    return !q || (task.title + ' ' + task.hito + ' ' + task.team + ' ' + task.id).toLocaleLowerCase('en').indexOf(q) >= 0;
  }
  function renderTaskList() {
    var visible = taskState.tasks.filter(taskMatches);
    taskUi.list.replaceChildren();
    taskUi.count.textContent = taskState.loaded ? String(visible.length) : '—';
    visible.forEach(function (task) {
      var card = node('button', 'task-card');
      var top = node('div', 'task-card__top');
      var foot = node('div', 'task-card__foot');
      card.type = 'button'; card.dataset.taskId = String(task.id);
      card.setAttribute('aria-selected', task.id === taskState.selected ? 'true' : 'false');
      top.appendChild(node('span', 'task-card__id', '#' + task.id));
      top.appendChild(node('span', 'task-card__state task-card__state--' + task.state.toLocaleLowerCase('en'), stateLabel(task.state)));
      card.appendChild(top);
      card.appendChild(node('h3', '', task.title));
      card.appendChild(node('p', '', task.hito || (task.wf_name ? 'Workflow ' + task.wf_name : 'No associated milestone')));
      foot.appendChild(node('span', '', task.team || 'Unassigned'));
      var noteCount = notesCountOf(task);
      foot.appendChild(node('span', '', noteCount + ' note' + (noteCount === 1 ? '' : 's')));
      card.appendChild(foot);
      taskUi.list.appendChild(card);
    });
    taskUi.empty.hidden = !taskState.loaded || visible.length !== 0;
    renderTaskStatus();
  }
  function renderTaskStatus() {
    taskUi.list.setAttribute('aria-busy', taskState.loading ? 'true' : 'false');
    taskUi.loading.hidden = taskState.loaded || !taskState.loading;
    if (!taskState.loaded) {
      taskUi.count.textContent = '—';
      taskUi.empty.hidden = true;
    }
  }
  function taskButton(label, action, className) {
    var button = node('button', className || 'button button--quiet', label);
    button.type = 'button'; button.dataset.taskAction = action;
    return button;
  }
  function renderTaskDetail() {
    var task = taskState.tasks.find(function (item) { return item.id === taskState.selected; });
    var head, actions, meta, notes;
    taskUi.detail.replaceChildren();
    if (!task) {
      var empty = node('div', 'manage-empty');
      empty.appendChild(node('strong', '', 'Select a task'));
      empty.appendChild(node('span', '', 'You will see its status, notes, links, and actions.'));
      taskUi.detail.appendChild(empty); return;
    }
    head = node('div', 'task-detail__head');
    var heading = node('div'); heading.appendChild(node('p', 'section-kicker', 'Task #' + task.id)); heading.appendChild(node('h2', '', task.title));
    head.appendChild(heading); head.appendChild(node('span', 'task-card__state task-card__state--' + task.state.toLocaleLowerCase('en'), stateLabel(task.state)));
    taskUi.detail.appendChild(head);
    meta = node('div', 'task-detail__meta');
    meta.appendChild(node('span', '', task.team || 'Unassigned'));
    if (task.hito) { meta.appendChild(node('span', '', task.hito)); }
    if (task.wf_name) { meta.appendChild(node('span', '', 'workflow ' + task.wf_name)); }
    if (task.parent > 0) { meta.appendChild(node('span', '', 'subtask of #' + task.parent)); }
    if (task.depends.length) { meta.appendChild(node('span', '', 'depends on ' + task.depends.map(function (id) { return '#' + id; }).join(', '))); }
    if (taskState.detailId === task.id && taskState.subtasks.length) {
      meta.appendChild(node('span', '', 'subtasks ' + taskState.subtasks.map(function (id) { return '#' + id; }).join(', ')));
    }
    taskUi.detail.appendChild(meta);
    actions = node('div', 'task-detail__actions');
    actions.appendChild(taskButton(task.state === 'done' ? 'Reopen' : 'Complete', 'state', 'button button--primary'));
    actions.appendChild(taskButton('Note', 'note'));
    actions.appendChild(taskButton('Assign', 'assign'));
    actions.appendChild(taskButton('Delete', 'delete', 'button button--danger-quiet'));
    taskUi.detail.appendChild(actions);
    notes = node('section', 'task-notes'); notes.appendChild(node('h3', '', 'Notes and evidence'));
    // Render detail states from the data itself, in this order: a current error,
    // a record that actually contains notes, or a pending detail request. This
    // prevents stale flags from presenting old notes as current data.
    if (taskState.detailError) {
      var failure = node('p', 'registry-card__subtitle');
      failure.appendChild(document.createTextNode('Could not read the notes: ' + taskState.detailError + ' '));
      var retryButton = node('button', 'button button--quiet', 'Retry');
      retryButton.type = 'button';
      retryButton.dataset.taskAction = 'reload-detail';
      failure.appendChild(retryButton);
      notes.appendChild(failure);
    } else if (!Array.isArray(task.notes)) {
      notes.appendChild(node('p', 'registry-card__subtitle', 'Loading this task\'s notes…'));
    } else if (!task.notes.length) {
      notes.appendChild(node('p', 'registry-card__subtitle', 'There are no notes yet.'));
    } else {
      task.notes.slice().reverse().forEach(function (item) {
        var note = node('article', 'task-note'); note.appendChild(node('p', '', item.text)); note.appendChild(node('small', '', item.by + ' · ' + item.ts)); notes.appendChild(note);
      });
    }
    taskUi.detail.appendChild(notes);
  }
  function loadTeams() {
    return request('/api/teams').then(function (result) {
      if (!object(result.data) || !Array.isArray(result.data.teams)) { throw new Error('The team list does not match the contract.'); }
      teamsCache = result.data.teams.filter(function (team) { return object(team) && typeof team.name === 'string'; });
      taskUi.team.replaceChildren();
      var all = document.createElement('option'); all.value = ''; all.textContent = 'All'; taskUi.team.appendChild(all);
      teamsCache.forEach(function (team) { var option = document.createElement('option'); option.value = team.name; option.textContent = team.name; taskUi.team.appendChild(option); });
    });
  }
  function loadTaskDetail(id) {
    taskState.detailId = 0;
    taskState.detailError = '';
    taskState.subtasks = [];
    // Remove stale note bodies while reloading by replacing the row with a copy;
    // never mutate objects received from another component.
    var idx = taskState.tasks.findIndex(function (item) { return item.id === id; });
    if (idx >= 0 && Array.isArray(taskState.tasks[idx].notes)) {
      var copy = {};
      Object.keys(taskState.tasks[idx]).forEach(function (k) {
        if (k !== 'notes') { copy[k] = taskState.tasks[idx][k]; }
      });
      taskState.tasks[idx] = copy;
    }
    // Repaint immediately so a retry visibly returns to its loading state.
    renderTaskDetail();
    return request('/api/task/' + id).then(function (result) {
      var data = result.data;
      if (!object(data) || !validTaskDetail(data.task) || !Array.isArray(data.subtasks) ||
          !data.subtasks.every(function (item) { return Number.isSafeInteger(item) && item > 0; })) {
        throw new Error('The task record does not match the contract.');
      }
      var index = taskState.tasks.findIndex(function (item) { return item.id === id; });
      if (index >= 0) { taskState.tasks[index] = data.task; }
      taskState.detailId = id;
      taskState.subtasks = data.subtasks.slice();
      renderTaskList();
      renderTaskDetail();
    }).catch(function (error) {
      // Persist the failure for the detail panel instead of showing endless loading.
      taskState.detailError = error.message;
      notice(taskUi.notice, error.message, true);
      renderTaskDetail();
    });
  }
  function loadTasks(propagate) {
    taskState.loading = true;
    renderTaskStatus();
    var query = '?filter=' + encodeURIComponent(taskState.filter) + (taskState.team ? '&team=' + encodeURIComponent(taskState.team) : '');
    return Promise.all([request('/api/tasks' + query), teamsCache.length ? Promise.resolve() : loadTeams()]).then(function (results) {
      if (!object(results[0].data) || !Array.isArray(results[0].data.tasks) || !results[0].data.tasks.every(validTaskRow)) {
        throw new Error('The task list does not match the contract.');
      }
      taskState.tasks = results[0].data.tasks;
      // Fresh list rows are lightweight and contain no previously loaded notes.
      taskState.detailId = 0;
      taskState.detailError = '';
      if (!taskState.tasks.some(function (task) { return task.id === taskState.selected; })) { taskState.selected = taskState.tasks.length ? taskState.tasks[0].id : 0; }
      taskState.loaded = true; renderTaskList(); renderTaskDetail();
      if (taskState.selected) { return loadTaskDetail(taskState.selected); }
    }).catch(function (error) {
      notice(taskUi.notice, error.message, true);
      if (propagate === true) { throw error; }
    })
      .finally(function () { taskState.loading = false; renderTaskStatus(); });
  }
  function taskAction(action) {
    var task = taskState.tasks.find(function (item) { return item.id === taskState.selected; });
    if (!task) { return; }
    // Detail retries are explicit; never retry automatically after a failure.
    if (action === 'reload-detail') { loadTaskDetail(task.id); return; }
    if (action === 'state') {
      var next = task.state === 'done' ? 'open' : 'done';
      openDialog({title: next === 'done' ? 'Complete task #' + task.id : 'Reopen task #' + task.id,
        helpRoute: 'POST /api/task/<id>/state',
        help: next === 'done' ? 'Mark the work as complete. If it belongs to a workflow, the hub will enforce its guard.' : 'Return the task to open work.',
        submit: next === 'done' ? 'Complete' : 'Reopen', fields: [], action: function () {
          return mutate('/api/task/' + task.id + '/state', {state: next}, loadTasks, taskUi.notice);
        }});
    } else if (action === 'note') {
      openDialog({title: 'Add note to #' + task.id, helpRoute: 'POST /api/task/<id>/note', help: 'The note is stored with its author and date; use it for evidence or context that must persist.',
        fields: [{name: 'text', label: 'Note', type: 'textarea', required: true, maxLength: 4096,
          help: 'Maximum 4 KiB.'}], action: function (v) {
          return mutate('/api/task/' + task.id + '/note', v, loadTasks, taskUi.notice);
        }});
    } else if (action === 'assign') {
      openDialog({title: 'Assign task #' + task.id, helpRoute: 'POST /api/task/<id>/assign', help: 'Choose a team or leave it unassigned. The hub may prevent changes to workflow-governed tasks.',
        fields: [{name: 'team', label: 'Team', type: 'select', value: task.team,
          options: [{value: '', label: 'Unassigned'}].concat(teamsCache.map(function (team) { return team.name; }))}], action: function (v) {
          return mutate('/api/task/' + task.id + '/assign', v, loadTasks, taskUi.notice);
        }});
    } else if (action === 'delete') {
      openDialog({title: 'Delete task #' + task.id, kicker: 'Permanent deletion', helpRoute: 'POST /api/task/<id>/delete', help: 'The hub will reject linked tasks or tasks with subtasks. Enter the number to confirm.',
        danger: true, submit: 'Delete', fields: [{name: 'confirm', label: 'Task number', required: true}], action: function (v) {
          if (v.confirm !== String(task.id)) { return Promise.reject(new Error('The number does not match.')); }
          return mutate('/api/task/' + task.id + '/delete', {}, function () { taskState.selected = 0; return loadTasks(); }, taskUi.notice);
        }});
    }
  }
  function createTask() {
    openDialog({title: 'New task', helpRoute: 'POST /api/task', help: 'Create visible work for a team and include its context in the same step: the description is stored as the first note. Workflow milestones are managed from their graph.', submit: 'Create task',
      fields: [
        {name: 'title', label: 'Title', required: true, maxLength: 500, placeholder: 'Concrete outcome'},
        {name: 'team', label: 'Team', type: 'select', options: teamsCache.map(function (team) { return team.name; })},
        {name: 'milestone', label: 'Optional milestone', maxLength: 120, placeholder: 'What this will demonstrate'},
        {name: 'parent', label: 'Optional parent task', type: 'number', placeholder: 'ID'},
        {name: 'text', label: 'Description / first note', type: 'textarea', maxLength: 4096,
          help: 'Optional. Stored as the task\'s first note (with author and date), just like notes added later.',
          placeholder: 'Context, requirements, links… whatever the recipient needs to read first.'}
      ], action: function (v) {
        var body = {title: v.title, team: v.team}; if (v.milestone) { body.milestone = v.milestone; } if (v.parent) { body.parent = Number(v.parent); }
        // Create the task before its optional first note. If the note fails,
        // report that the task already exists so creation is never retried.
        if (!v.text || !v.text.trim()) {
          return mutate('/api/task', body, function (result) {
            if (object(result.data) && validTask(result.data.task)) { taskState.selected = result.data.task.id; }
            return loadTasks();
          }, taskUi.notice);
        }
        dialog.submit.disabled = true;
        dialog.error.hidden = true;
        return post('/api/task', body).then(function (result) {
          var createdTask = object(result.data) && validTask(result.data.task) ? result.data.task : null;
          if (!createdTask) { throw new Error('The creation response does not match the contract.'); }
          return post('/api/task/' + createdTask.id + '/note', {text: v.text}).then(function () {
            dialog.node.close();
            notice(taskUi.notice, 'Task #' + createdTask.id + ' created with its description.', false);
            taskState.selected = createdTask.id;
            return loadTasks();
          }).catch(function (noteError) {
            // The task exists; only its note failed and can be added manually.
            dialog.node.close();
            notice(taskUi.notice, 'Task #' + createdTask.id + ' WAS CREATED, but its description could not be saved: ' +
              noteError.message + ' — the task exists; add the note manually from its record. DO NOT repeat the creation.', true);
            taskState.selected = createdTask.id;
            return loadTasks();
          });
        }).catch(function (error) {
          dialog.error.textContent = error.message;
          dialog.error.hidden = false;
        }).finally(function () { dialog.submit.disabled = false; });
      }});
  }

  function openMessage() {
    var ready = teamsCache.length ? Promise.resolve() : loadTeams();
    ready.then(function () {
      var groupsReady = hasRegistry('groups') ? Promise.resolve() : loadRegistry('groups');
      return groupsReady;
    }).then(function () {
      var destinations = [{value: 'console', label: 'console'}, {value: 'all', label: 'all · entire fleet'}]
        .concat(teamsCache.map(function (team) { return team.name; }))
        .concat(registryState.groups.map(function (group) { return {value: '@' + group.name, label: '@' + group.name + ' · group'}; }));
      openDialog({title: 'Send message', kicker: 'Talk through Pizarra', helpRoute: 'POST /api/message', help: 'It will be sent as pzweb and attributed that way in the record. A group receives one copy per member.', submit: 'Send',
        fields: [{name: 'to', label: 'Destination', type: 'select', options: destinations, required: true},
          {name: 'text', label: 'Message', type: 'textarea', required: true, maxLength: 8192, help: 'Maximum 8 KiB.'}],
        action: function (v) {
          var target = document.getElementById('message-notice');
          dialog.submit.disabled = true;
          return post('/api/message', v).then(function (result) {
            var data = result.data;
            var message;
            dialog.node.close();
            if (object(data) && Number.isSafeInteger(data.seq)) {
              message = 'Message #' + data.seq + (data.queued ? ' queued for delivery.' : ' accepted.');
            } else if (object(data) && Number.isSafeInteger(data.broadcast) && Number.isSafeInteger(data.queued_count)) {
              message = 'Broadcast sent to ' + data.broadcast + ' recipients; ' + data.queued_count + ' were queued.';
            } else {
              throw new Error('The send response does not match either agreed format.');
            }
            notice(target, message, false);
          }).catch(function (error) {
            dialog.error.textContent = error.message; dialog.error.hidden = false;
          }).finally(function () { dialog.submit.disabled = false; });
        }});
    }).catch(function (error) { notice(document.getElementById('message-notice'), error.message, true); });
  }

  var registryMeta = {
    teams: {title: 'Teams', kicker: 'People and agents', help: 'Who does the work and how they relate.', singular: 'team'},
    groups: {title: 'Groups', kicker: 'Coordination', help: 'Sets of teams, owners, and a shared project.', singular: 'group'},
    projects: {title: 'Projects', kicker: 'Responsibility', help: 'Product areas and the person accountable for them.', singular: 'project'},
    apps: {title: 'Applications', kicker: 'Live inventory', help: 'What exists, who maintains it, and where it lives.', singular: 'app'}
  };
  function validRegistry(kind, value) {
    if (!object(value) || typeof value.name !== 'string') { return false; }
    if (kind === 'teams') { return Number.isSafeInteger(value.id) && typeof value.speciality === 'string' && typeof value.parent === 'string' && Number.isSafeInteger(value.open_tasks) && typeof value.slave === 'boolean' && typeof value.workdir === 'string' && (!own(value, 'host') || typeof value.host === 'string'); }
    if (kind === 'groups') { return typeof value.project === 'string' && typeof value.boss === 'string' && Array.isArray(value.members) && value.members.every(function (v) { return typeof v === 'string'; }) && Array.isArray(value.member_ids); }
    if (kind === 'projects') { return typeof value.boss === 'string'; }
    return typeof value.team === 'string' && typeof value.purpose === 'string' && typeof value.hasdoc === 'boolean';
  }
  function hasRegistry(kind) { return registryState.have[kind] === true; }
  function isRegistryLoading(kind) { return registryState.loading[kind] === true; }
  function renderRegistryStatus() {
    var kind = registryState.kind;
    registryUi.grid.setAttribute('aria-busy', isRegistryLoading(kind) ? 'true' : 'false');
    registryUi.loading.hidden = hasRegistry(kind) || !isRegistryLoading(kind);
    if (!hasRegistry(kind)) { registryUi.empty.hidden = true; }
  }
  // One registry per request. Persist failures so an error is never rendered as
  // a verified empty registry.
  function loadRegistry(kind, propagate) {
    if (isRegistryLoading(kind)) { return Promise.resolve(); }
    registryState.loading[kind] = true;
    registryState.error[kind] = '';
    renderRegistryStatus();
    return request('/api/' + kind).then(function (result) {
      var list = object(result.data) ? result.data[kind] : null;
      if (!Array.isArray(list) || !list.every(function (item) { return validRegistry(kind, item); })) {
        throw new Error('The ' + kind + ' registry does not match the contract.');
      }
      registryState[kind] = list.slice().sort(function (a, b) { return a.name.localeCompare(b.name, 'en'); });
      registryState.have[kind] = true;
      if (kind === 'teams') { teamsCache = registryState.teams; }
      var count = document.querySelector('[data-registry-count="' + kind + '"]');
      if (count) { count.textContent = String(list.length); }
    }).catch(function (error) {
      registryState.error[kind] = error.message;
      notice(registryUi.notice, error.message, true);
      if (propagate === true) { throw error; }
    }).finally(function () {
      registryState.loading[kind] = false;
      if (registryState.kind === kind) { renderRegistry(); } else { renderRegistryStatus(); }
    });
  }
  // After a mutation, refresh the visible registry and mark related registries
  // stale. Inactive tabs perform no background reads, including count-only reads.

  /* THE PROJECT LIST IS ONLY LOADED WHEN THE PROJECTS TAB HAS BEEN VISITED, and
     the edit dialogs for a team and for a group both offered a <select> built
     from it. Freshly opened on the Teams tab, that dropdown rendered with a
     single option -"None"- for an entity that really did have a project.
     Two harms from one control: it LIED about the current value, and because a
     <select> falls back to its first option, saving without touching anything
     POSTed an empty project and the hub deleted it, then the screen reported
     "Change applied and confirmed by the hub". A control that turns "I do not
     know" into "erase it" is worse than having no control at all.

     So the current value is ALWAYS an option, whatever the list happens to
     contain - which makes save-without-touching a no-op instead of a deletion,
     even when the list never loads at all. It is also how a value that no
     longer names a real project stays visible instead of being silently
     swallowed: it says "(current)" and the operator can see there is something
     to fix. */
  function projectOptions(current) {
    var opts = [{value: '', label: 'None'}];
    var seenProjects = Object.create(null);
    registryState.projects.forEach(function (project) {
      if (object(project) && typeof project.name === 'string' && project.name &&
          !seenProjects[project.name]) {
        seenProjects[project.name] = true;
        opts.push(project.name);
      }
    });
    if (current && !seenProjects[current]) {
      opts.push({value: current, label: current + ' (current)'});
    }
    return opts;
  }

  function loadRegistries(propagate) {
    ['teams', 'groups', 'projects', 'apps'].forEach(function (k) {
      if (k !== registryState.kind) { registryState.have[k] = false; }
    });
    return loadRegistry(registryState.kind, propagate);
  }
  function registryCard(item) {
    var kind = registryState.kind;
    var card = node('article', 'registry-card');
    var top = node('div', 'registry-card__top');
    var facts = node('div', 'registry-card__facts');
    var actions = node('div', 'registry-card__actions');
    var icon = {teams: 'EQ', groups: '@', projects: 'PR', apps: 'AP'}[kind];
    top.appendChild(node('span', 'registry-card__icon', icon));
    if (kind === 'teams' && item.slave) { top.appendChild(node('span', 'task-card__state', 'subordinate')); }
    if (kind === 'apps' && item.hasdoc) { top.appendChild(node('span', 'task-card__state task-card__state--done', 'manual')); }
    card.appendChild(top); card.appendChild(node('h3', '', item.name));
    if (kind === 'teams') {
      card.appendChild(node('p', 'registry-card__subtitle', item.speciality || 'No specialty described'));
      facts.appendChild(node('span', '', item.parent ? 'depends on ' + item.parent : 'root'));
      facts.appendChild(node('span', '', item.open_tasks + ' open'));
      if (typeof item.host === 'string' && item.host) { facts.appendChild(node('span', '', item.host)); }
    } else if (kind === 'groups') {
      card.appendChild(node('p', 'registry-card__subtitle', item.members.length ? item.members.join(', ') : 'Empty group'));
      facts.appendChild(node('span', '', item.members.length + ' members'));
      facts.appendChild(node('span', '', item.boss || 'no owner'));
      if (item.project) { facts.appendChild(node('span', '', item.project)); }
      // muted members: still in the group, just not receiving @group sends.
      // Tolerant of an older hub that omits the field.
      var muted = item.excluded || [];
      if (muted.length) { facts.appendChild(node('span', '', 'muted: ' + muted.join(', '))); }
      // on-idle policy: what happens when EVERY member goes idle. Shows whether
      // it is enabled and what it does. Tolerant of an older hub (no field).
      var onIdleMode = (item.on_idle || '').toLowerCase();
      if (onIdleMode && onIdleMode !== 'off') {
        var onIdleText = onIdleMode === 'boss' ? 'notify the owner' : onIdleMode === 'all' ? 'notify everyone' : 'notify: ' + onIdleMode;
        facts.appendChild(node('span', '', 'when idle: ' + onIdleText));
      } else {
        facts.appendChild(node('span', '', 'when idle: nothing'));
      }
      // live "all stopped" alarm indicator (all members idle right now).
      if (item.all_idle) {
        facts.appendChild(node('span', 'registry-card__alarm',
          (onIdleMode && onIdleMode !== 'off') ? '⚠ ALL IDLE · signal ready' : '⚠ ALL IDLE'));
      } else if (item.any_blocked) {
        facts.appendChild(node('span', '', 'one member BLOCKED on a permission'));
      }
    } else if (kind === 'projects') {
      card.appendChild(node('p', 'registry-card__subtitle', item.boss ? 'Owner: ' + item.boss : 'No owner'));
    } else {
      card.appendChild(node('p', 'registry-card__subtitle', item.purpose || 'No purpose described'));
      facts.appendChild(node('span', '', item.team || 'no team'));
    }
    card.appendChild(facts);
    // Relationship details are available only for apps and projects and are
    // loaded on demand. Team ownership is edited through the app itself.
    var isApp = kind === 'apps';
    var hasRelationships = isApp || kind === 'projects';
    if (hasRelationships) {
      var relationshipsButton = taskButton(isApp ? 'Projects' : 'Apps', 'relationships');
      if (isApp) { relationshipsButton.dataset.appRelationships = '1'; }
      actions.appendChild(relationshipsButton);
    }
    // Expose a team's owned applications from the team card as the inverse view
    // of each app's owner relationship.
    if (kind === 'teams') { actions.appendChild(taskButton('Apps', 'teamapps')); }
    // Create app-project assignments from the relationship detail, where the
    // pair and its project-specific functionality are already in context.
    actions.appendChild(taskButton('Edit', 'edit'));
    if (kind === 'apps') {
      // Keep the common remove-owner action directly discoverable on the app.
      actions.appendChild(taskButton('Remove team', 'unteam'));
      actions.appendChild(taskButton('Manual', 'doc'));
      actions.appendChild(taskButton('Undo', 'undo'));
    }
    actions.appendChild(taskButton('Delete', 'delete', 'button button--danger-quiet'));
    Array.prototype.forEach.call(actions.children, function (button) { button.dataset.registryName = item.name; });
    card.appendChild(actions); return card;
  }
  function renderRegistry() {
    var meta = registryMeta[registryState.kind];
    var q = registryState.search.toLocaleLowerCase('en');
    /* Search values rather than serialized field names. Keys and boolean
       literals are schema details, not user-visible registry content. */
    function searchableText(value) {
      if (value === null || value === undefined) { return ''; }
      if (Array.isArray(value)) { return value.map(searchableText).join(' '); }
      if (typeof value === 'object') {
        return Object.keys(value).map(function (k) { return searchableText(value[k]); }).join(' ');
      }
      if (typeof value === 'boolean') { return ''; }   // Booleans are not searchable content.
      return String(value);
    }
    var list = registryState[registryState.kind].filter(function (item) {
      return !q || searchableText(item).toLocaleLowerCase('en').indexOf(q) >= 0;
    });
    registryUi.title.textContent = meta.title; registryUi.kicker.textContent = meta.kicker; registryUi.help.textContent = meta.help;
    registryUi.search.placeholder = 'Search ' + meta.title.toLocaleLowerCase('en');
    registryUi.grid.replaceChildren();
    // A failed registry read is not an empty registry.
    if (registryState.error[registryState.kind]) {
      var failure = node('div', 'records-empty');
      failure.appendChild(node('strong', '', 'Could not read ' + meta.title.toLocaleLowerCase('en')));
      failure.appendChild(node('span', '', registryState.error[registryState.kind]));
      registryUi.grid.appendChild(failure);
      registryUi.empty.hidden = true;
      renderRegistryStatus();
      return;
    }
    list.forEach(function (item) { registryUi.grid.appendChild(registryCard(item)); });
    registryUi.empty.hidden = !hasRegistry(registryState.kind) || list.length !== 0;
    renderRegistryStatus();
  }
  function splitMembers(value) { return value.split(',').map(function (v) { return v.trim(); }).filter(Boolean); }
  function teamOptions(blank) { var list = teamsCache.map(function (team) { return team.name; }); return blank ? [{value: '', label: blank}].concat(list) : list; }
  function createRegistry() {
    var kind = registryState.kind;
    if (kind === 'teams') {
      openDialog({title: 'New team', helpRoute: 'POST /api/team', help: 'Create the organizational identity and, when execution fields are provided, configure its process in the hub as well.', submit: 'Create team',
        fields: [{name: 'name', label: 'Name', required: true}, {name: 'speciality', label: 'Specialty'},
          {name: 'parent', label: 'Parent team', type: 'select', options: teamOptions('None')},
          {name: 'host', label: 'Optional host', placeholder: 'Name of the host that runs it'},
          {name: 'prompt', label: 'Instructions', type: 'textarea'},
          {name: 'session', label: 'Session', help: 'tmux session name; “-” leaves the team with inbox access only.'},
          {name: 'launch', label: 'COMMAND run by the hub', type: 'textarea', help: 'DANGER: the hub runs this text as a system command.'}], action: function (v) { return mutate('/api/team', v, loadRegistries, registryUi.notice); }});
    } else if (kind === 'groups') {
      openDialog({title: 'New group', helpRoute: 'POST /api/group', help: 'Enter comma-separated members; the server receives an exact JSON list.', submit: 'Create group',
        fields: [{name: 'name', label: 'Name', required: true}, {name: 'members', label: 'Members', required: true, placeholder: 'frontend, backend'}],
        action: function (v) { return mutate('/api/group', {name: v.name, members: splitMembers(v.members)}, loadRegistries, registryUi.notice); }});
    } else if (kind === 'projects') {
      openDialog({title: 'New project', helpRoute: 'POST /api/project/<name>/boss', help: 'In Pizarra, a project is created by assigning an owner.', submit: 'Create project',
        fields: [{name: 'name', label: 'Name', required: true}, {name: 'boss', label: 'Owner', type: 'select', options: teamOptions(), required: true}],
        action: function (v) { var name = v.name; delete v.name; return mutate('/api/project/' + pathPart(name) + '/boss', v, loadRegistries, registryUi.notice); }});
    } else {
      openDialog({title: 'New application', helpRoute: 'POST /api/app', help: 'Register a maintainable component: purpose, owner, and location.', submit: 'Create app',
        fields: [{name: 'name', label: 'Name', required: true}, {name: 'team', label: 'Team', type: 'select', options: teamOptions(), required: true},
          {name: 'purpose', label: 'Purpose', required: true}, {name: 'repo', label: 'Repository'}, {name: 'path', label: 'Path'}, {name: 'detail', label: 'Details', type: 'textarea'}],
        action: function (v) { return mutate('/api/app', v, loadRegistries, registryUi.notice); }});
    }
  }
  function editRegistry(kind, name, action) {
    var item = registryState[kind].find(function (entry) { return entry.name === name; });
    if (!item) { return; }
    // Relationship details are read-only views. Validate the full app-project
    // pair before rendering it.
    if (action === 'assign-project') {
      // Assign an app to an existing project. The project-specific role is
      // intentionally optional according to the contract.
      var projectsReady = hasRegistry('projects') ? Promise.resolve() : loadRegistry('projects');
      projectsReady.then(function () {
        var options = registryState.projects.map(function (p) { return p.name; });
        if (!options.length) {
          notice(registryUi.notice, 'There are no projects yet. Create one first on the Projects tab.', true);
          return;
        }
        openDialog({title: 'Assign ' + name + ' to a project', kicker: 'App–project relationship', helpRoute: 'POST /api/app/<name>/project',
          help: 'Functionality belongs to the PAIR: what this app contributes to that project, distinct from its own purpose. An empty value is valid.',
          submit: 'Assign',
          fields: [
            {name: 'project', label: 'Project', type: 'select', options: options, required: true},
            {name: 'role', label: 'Functionality in this project', type: 'textarea', maxLength: 1024,
              placeholder: 'What this app contributes HERE (optional)'}
          ],
          action: function (v) {
            var body = {project: v.project};
            if (v.role && v.role.trim()) { body.role = v.role; }
            return mutate('/api/app/' + pathPart(name) + '/project', body, function () {
              // Refresh the app registry currently being viewed.
              return loadRegistry('apps');
            }, registryUi.notice);
          }});
      }).catch(function (error) { notice(registryUi.notice, error.message, true); });
      return;
    }
    if (action === 'assign-app') {
      // From a project, select an existing app and use the same app-project
      // endpoint with the project fixed; the relationship is symmetric in the UI.
      var appsReady = hasRegistry('apps') ? Promise.resolve() : loadRegistry('apps');
      appsReady.then(function () {
        var candidates = registryState.apps.map(function (a) { return a.name; });
        if (!candidates.length) {
          notice(registryUi.notice, 'There are no apps yet. Register one first on the Apps tab.', true);
          return;
        }
        openDialog({title: 'Add an app to ' + name, kicker: 'App–project relationship', helpRoute: 'POST /api/app/<name>/project',
          help: 'Functionality belongs to the PAIR: what that app contributes TO THIS project, distinct from its own purpose. An empty value is valid.',
          submit: 'Assign',
          fields: [
            {name: 'app', label: 'App', type: 'select', options: candidates, required: true},
            {name: 'role', label: 'Functionality in this project', type: 'textarea', maxLength: 1024,
              placeholder: 'What that app contributes HERE (optional)'}
          ],
          action: function (v) {
            var body = {project: name};
            if (v.role && v.role.trim()) { body.role = v.role; }
            return mutate('/api/app/' + pathPart(v.app) + '/project', body, function () {
              // Refresh the project registry currently being viewed.
              return loadRegistry('projects');
            }, registryUi.notice);
          }});
      }).catch(function (error) { notice(registryUi.notice, error.message, true); });
      return;
    }
    if (action === 'relationships') {
      // Reject accidentally wired relationship buttons for unsupported kinds.
      if (kind !== 'apps' && kind !== 'projects') {
        notice(registryUi.notice, 'Relationship records exist only for apps and projects.', true);
        return;
      }
      var path = kind === 'apps' ? '/api/app/' + pathPart(name) : '/api/project/' + pathPart(name);
      // Load the lightweight project list on demand for assignment controls.
      var projectsReady = hasRegistry('projects') ? Promise.resolve() : loadRegistry('projects');
      projectsReady.catch(function () {});
      request(path).then(function (result) {
        var data = object(result.data) ? result.data : null;
        var card = null;
        if (kind === 'apps') {
          card = object(data) && object(data.app) ? data.app : null;
        } else {
          card = object(data) && object(data.project) ? data.project : null;
        }
        if (!card) { throw new Error('The record does not match the contract.'); }
        var relationships = kind === 'apps' ? card.projects : card.apps;
        if (!Array.isArray(relationships) || !relationships.every(function (p) {
          return object(p) && typeof p.name === 'string' && typeof p.role === 'string';
        })) { throw new Error('The assignment list does not match the contract.'); }
        openDialog({title: (kind === 'apps' ? 'App ' : 'Project ') + name, kicker: 'Record', submit: 'Close',
          help: kind === 'apps' ?
            'Projects this app contributes to, including its functionality in each pair.' :
            'Apps that build this project, including the functionality of each pair.',
          fields: [], action: function () { return Promise.resolve(); }});
        var container = dialog.fields;
        if (!relationships.length) {
          container.appendChild(node('p', 'registry-card__subtitle',
            kind === 'apps' ? 'This app does not belong to any project yet.' : 'This project does not have any assigned apps yet.'));
        } else {
          relationships.forEach(function (p) {
            var row = node('div', 'editor-field');
            row.appendChild(node('strong', '', p.name));
            if (p.role) { row.appendChild(node('small', '', p.role)); }
            // Remove a relationship from either side, with typed confirmation.
            var removeButton = node('button', 'button button--danger-quiet', 'Remove');
            removeButton.type = 'button';
            removeButton.dataset.unprojectApp = kind === 'apps' ? name : p.name;
            removeButton.dataset.unprojectProject = kind === 'apps' ? p.name : name;
            row.appendChild(removeButton);
            container.appendChild(row);
          });
        }
        // Add relationships from the detail where they are being inspected.
        var addButton = node('button', 'button', kind === 'apps' ? 'Assign to a project' : 'Add an app');
        addButton.type = 'button';
        addButton.dataset.relationshipAction = kind === 'apps' ? 'assign-project' : 'assign-app';
        addButton.dataset.relationshipName = name;
        /* Store the entity kind on the button. The active tab may change while
           an asynchronous detail request is still open. */
        addButton.dataset.relationshipKind = kind;
        container.appendChild(addButton);
        // Registry kinds are plural; use the exact contractual kind.
        if (kind === 'projects') { container.appendChild(node('p', 'registry-card__subtitle', 'Owner: ' + (card.boss || 'none'))); }
      }).catch(function (error) { notice(registryUi.notice, error.message, true); });
      return;
    }
    if (action === 'teamapps') {
      // The team record already includes app names and purposes in appsdetail.
      request('/api/team/' + pathPart(name)).then(function (result) {
        var team = object(result.data) ? result.data.team : null;
        if (!object(team) || !Array.isArray(team.appsdetail)) {
          throw new Error('The team record does not match the contract.');
        }
        openDialog({title: 'Apps owned by ' + name, kicker: 'Record', submit: 'Close',
          help: 'Applications owned by this team. Edit opens the app record; remove the team from there.',
          fields: [], action: function () { return Promise.resolve(); }});
        var container = dialog.fields;
        if (!team.appsdetail.length) {
          container.appendChild(node('p', 'registry-card__subtitle',
            'This team does not own any applications.'));
          return;
        }
        team.appsdetail.forEach(function (a) {
          var row = node('div', 'editor-field');
          row.appendChild(node('strong', '', a.name));
          if (a.purpose) { row.appendChild(node('small', '', a.purpose)); }
          var editButton = node('button', 'button', 'Edit');
          editButton.type = 'button';
          editButton.dataset.openApp = a.name;
          row.appendChild(editButton);
          container.appendChild(row);
        });
      }).catch(function (error) { notice(registryUi.notice, error.message, true); });
      return;
    }
    if (action === 'unteam') {
      openDialog({title: 'Remove ' + name + ' from its team', kicker: 'Change owner',
        helpRoute: 'POST /api/app/<name>/set',
        help: 'The app is NOT deleted and its projects are NOT changed: it simply no longer has an owning team. You can assign another one from Edit later.',
        submit: 'Remove team',
        fields: [{name: 'confirm', label: 'Enter the app name', required: true}],
        action: function (v) {
          if (v.confirm !== name) { return Promise.reject(new Error('The name does not match.')); }
          return mutate('/api/app/' + pathPart(name) + '/set', {field: 'team', value: ''},
            function () { return loadRegistry('apps'); }, registryUi.notice);
        }});
      return;
    }
    if (action === 'delete') {
      var deleteHelp = {teams: 'POST /api/team/<name>/remove', groups: 'POST /api/group/<name>/remove',
        projects: 'POST /api/project/<name>/remove', apps: 'POST /api/app/<name>/remove'}[kind] || '';
      openDialog({title: 'Delete ' + registryMeta[kind].singular + ' ' + name, kicker: 'Permanent deletion', helpRoute: deleteHelp, help: 'Enter the full name. The hub will reject relationships that must be resolved first.', danger: true, submit: 'Delete',
        fields: [{name: 'confirm', label: 'Full name', required: true}], action: function (v) {
          if (v.confirm !== name) { return Promise.reject(new Error('The name does not match.')); }
          var routes = {teams: '/api/team/', groups: '/api/group/', projects: '/api/project/', apps: '/api/app/'};
          return mutate(routes[kind] + pathPart(name) + '/remove', {}, loadRegistries, registryUi.notice);
        }}); return;
    }
    if (kind === 'teams') {
      request('/api/team/' + pathPart(name)).then(function (result) {
        var team = object(result.data) ? result.data.team : null;
        if (!object(team)) { throw new Error('The team record does not match the contract.'); }
        openDialog({title: 'Edit team ' + name, helpRoute: 'POST /api/team/<name>/set', help: 'One command changes one field. An empty value removes it when the hub allows it.',
          fields: [{name: 'field', label: 'Field', type: 'select', options: [
            {value: 'prompt', label: 'Instructions'}, {value: 'speciality', label: 'Specialty'}, {value: 'parent', label: 'Parent team'},
            {value: 'project', label: 'Project'}, {value: 'slave', label: 'Subordinate'},
            {value: 'launch', label: 'Startup COMMAND'}, {value: 'session', label: 'Session'},
            {value: 'user', label: 'Process user'}, {value: 'workdir', label: 'Working directory'}]},
            {name: 'value', label: 'New value', value: team.prompt}],
          action: function (v) { return mutate('/api/team/' + pathPart(name) + '/set', v, loadRegistries, registryUi.notice); }});
        var teamField = dialog.form.elements.namedItem('field');
        var teamValues = {prompt: team.prompt, speciality: team.speciality, parent: team.parent,
          project: team.project, slave: team.slave ? 'on' : 'off', launch: team.launch,
          session: team.session, user: team.user, workdir: team.workdir};
        function syncTeamValue() {
          var selected = teamField.value;
          var spec = {name: 'value', label: 'Current / new value', value: teamValues[selected] || ''};
          var executes = ['launch', 'session', 'user', 'workdir'].indexOf(selected) >= 0;
          dialog.kicker.textContent = executes ? 'DANGER · HUB EXECUTION' : 'Manage';
          dialog.submit.className = 'button ' + (executes ? 'button--danger-quiet' : 'button--primary');
          if (selected === 'prompt') {
            spec.type = 'textarea';
          } else if (selected === 'parent') {
            spec.type = 'select';
            spec.options = teamOptions('None');
          } else if (selected === 'project') {
            spec.type = 'select';
            spec.options = projectOptions(spec.value);
          } else if (selected === 'slave') {
            spec.type = 'select';
            spec.options = [{value: 'off', label: 'No'}, {value: 'on', label: 'Yes'}];
            spec.help = 'The screen shows Yes/No; the server receives on/off.';
          } else if (selected === 'launch') {
            spec.type = 'textarea';
            spec.label = 'Current / new COMMAND';
            spec.help = 'DANGER: when saved, the hub will use this text as a system command to start the team.';
          } else if (selected === 'session') {
            spec.help = 'Controls the associated tmux session; “-” leaves the team with inbox access only.';
          } else if (selected === 'user') {
            spec.help = 'An empty value or root runs the command under the hub daemon account.';
          } else if (selected === 'workdir') {
            spec.help = 'Directory from which the hub runs the command.';
          }
          replaceDialogField(spec);
        }
        teamField.addEventListener('change', syncTeamValue);
        syncTeamValue();
      }).catch(function (error) { notice(registryUi.notice, error.message, true); });
    } else if (kind === 'groups') {
      openDialog({title: 'Edit group @' + name, help: 'Choose one operation. Add and remove receive exact lists, never interpreted text.',
        fields: [{name: 'operation', label: 'Operation', type: 'select', options: [
          {value: 'add', label: 'Add members'}, {value: 'remove', label: 'Remove members'}, {value: 'boss', label: 'Change owner'}, {value: 'project', label: 'Change project'}, {value: 'exclude', label: 'Mute from @group'}]},
          {name: 'value', label: 'Value', placeholder: 'Comma-separated members, team, or project'}],
        action: function (v) {
          if (v.operation === 'add') { return mutate('/api/group', {name: name, members: splitMembers(v.value)}, loadRegistries, registryUi.notice); }
          if (v.operation === 'remove') { return mutate('/api/group/' + pathPart(name) + '/remove', {members: splitMembers(v.value)}, loadRegistries, registryUi.notice); }
          // exclude REPLACES the whole muted set (empty clears it); the server
          // field is `excluded`, not the operation name, so it needs its own line.
          if (v.operation === 'exclude') { return mutate('/api/group/' + pathPart(name) + '/exclude', {excluded: v.value || ''}, loadRegistries, registryUi.notice); }
          var body = {}; body[v.operation] = v.value; return mutate('/api/group/' + pathPart(name) + '/' + v.operation, body, loadRegistries, registryUi.notice);
        }});
      var groupOperation = dialog.form.elements.namedItem('operation');
      function syncGroupValue() {
        var selected = groupOperation.value;
        var spec = {name: 'value', label: 'Value', value: ''};
        if (selected === 'add') {
          setDialogHelp('POST /api/group', 'Add members to the group without changing existing members.');
          spec.label = 'Members to add';
          spec.placeholder = 'frontend, backend';
        } else if (selected === 'remove') {
          setDialogHelp('POST /api/group/<name>/remove', 'Remove exactly the listed members; this form never deletes the entire group.');
          spec.label = 'Members to remove';
          spec.placeholder = item.members.join(', ');
        } else if (selected === 'boss') {
          setDialogHelp('POST /api/group/<name>/boss', 'Change the group owner.');
          spec.label = 'Current / new owner';
          spec.type = 'select';
          spec.value = item.boss;
          spec.options = teamOptions('No owner');
        } else if (selected === 'exclude') {
          setDialogHelp('POST /api/group/<name>/exclude', 'Mute members from group sends: they remain members but do not receive @group messages. Replaces the entire set; an empty value clears it.');
          spec.label = 'Muted members (replaces the set; empty clears it)';
          spec.value = (item.excluded || []).join(', ');
          spec.placeholder = item.members.join(', ');
        } else {
          setDialogHelp('POST /api/group/<name>/project', 'Change the project associated with the group.');
          spec.label = 'Current / new project';
          spec.type = 'select';
          spec.value = item.project;
          spec.options = projectOptions(item.project);
        }
        replaceDialogField(spec);
      }
      groupOperation.addEventListener('change', syncGroupValue);
      syncGroupValue();
    } else if (kind === 'projects') {
      openDialog({title: 'Owner of ' + name, helpRoute: 'POST /api/project/<name>/boss', help: 'An empty assignment is not available: use Delete to remove the project.', fields: [
        {name: 'boss', label: 'Owner', type: 'select', value: item.boss, options: teamOptions(), required: true}],
        action: function (v) { return mutate('/api/project/' + pathPart(name) + '/boss', v, loadRegistries, registryUi.notice); }});
    } else if (action === 'doc') {
      request('/api/app/' + pathPart(name) + '/doc').then(function (result) {
        /* A missing manual body is a contract failure, not an empty manual. */
        if (!object(result.data) || typeof result.data.body !== 'string') {
          throw new Error('The manual does not match the contract: its text is missing. ' +
            'Open the application record for ' + name + ' and try again.');
        }
        var body = result.data.body;
        openDialog({title: 'Manual for ' + name, helpRoute: 'POST /api/app/<name>/doc', help: 'Plain text shared through Pizarra. HTML is not interpreted.', submit: 'Save manual',
          fields: [{name: 'text', label: 'Manual', type: 'textarea', value: body, required: true}],
          action: function (v) { return mutate('/api/app/' + pathPart(name) + '/doc', v, loadRegistries, registryUi.notice); }});
      }).catch(function (error) { notice(registryUi.notice, error.message, true); });
    } else if (action === 'undo') {
      request('/api/app/' + pathPart(name) + '/history').then(function (result) {
        var history = object(result.data) && typeof result.data.history === 'string' ? result.data.history : null;
        if (history === null) { throw new Error('The app history does not match the contract.'); }
        /* NEVER PARSE BY COLUMN WIDTH. The hub pads the author with %-10s, and
           the previous pattern demanded two or more spaces before the verb - so
           it silently stopped matching as soon as an author's name reached ten
           characters and the padding collapsed to the single separator space.
           It happens whenever an author's name exactly fills the padded column:
           the screen would report no history even though the points remained
           restorable. The width is presentation; the SHAPE is the contract. */
        var lines = history.split(/\r?\n/).filter(function (line) { return line.trim() !== ''; });
        var recognized = 0;
        var choices = lines.map(function (line) {
          /* The hub lists every app history operation, but undo only accepts
             field changes and manual replacements. Offering add/remove here
             creates a selectable action that the hub will always reject. */
          if (/^snap\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+/.test(line)) { recognized += 1; }
          var match = /^snap\s+(\d+)\s+\S+\s+\S+\s+\S+\s+(?:set|setdoc)\b/.exec(line);
          return match ? {value: match[1], label: line} : null;
        }).filter(Boolean);
        /* AND AN UNREADABLE ANSWER IS NOT AN EMPTY ONE. If the hub sent lines and
           none of them has a shape we know, saying "no history" tells the operator
           to stop looking - which is how the defect above stayed invisible. Say
           the truth instead: something came back and we could not read it. */
        if (!choices.length && lines.length && !recognized) {
          throw new Error('The hub returned history, but none of its lines could be interpreted. ' +
            'The format may have changed.');
        }
        if (!choices.length) { throw new Error('The application does not have any history points yet.'); }
        openDialog({title: 'Roll back ' + name, helpRoute: 'POST /api/app/<name>/undo', help: 'Choose an actual history point. The current app is saved before restoration, so you can also move forward again.', submit: 'Restore this point',
          fields: [{name: 'snapshot', label: 'History point', type: 'select', options: choices, required: true}],
          action: function (v) { return mutate('/api/app/' + pathPart(name) + '/undo', {snapshot: Number(v.snapshot)}, loadRegistries, registryUi.notice); }});
      }).catch(function (error) { notice(registryUi.notice, error.message, true); });
    } else {
      request('/api/app/' + pathPart(name)).then(function (result) {
        var app = object(result.data) ? result.data.app : null;
        if (!object(app)) { throw new Error('The app record does not match the contract.'); }
        openDialog({title: 'Edit app ' + name, helpRoute: 'POST /api/app/<name>/set', help: 'One command changes one field; the inventory is refreshed afterward.',
          fields: [{name: 'field', label: 'Field', type: 'select', options: ['team', 'purpose', 'repo', 'path', 'detail']},
            {name: 'value', label: 'New value', value: app.team}],
          action: function (v) { return mutate('/api/app/' + pathPart(name) + '/set', v, loadRegistries, registryUi.notice); }});
        var appField = dialog.form.elements.namedItem('field');
        var appValues = {team: app.team, purpose: app.purpose, repo: app.repo, path: app.path, detail: app.detail};
        function syncAppValue() {
          var selected = appField.value;
          var spec = {name: 'value', label: 'Current / new value', value: appValues[selected] || ''};
          if (selected === 'team') {
            spec.type = 'select';
            spec.options = teamOptions();
          } else if (selected === 'detail') {
            spec.type = 'textarea';
          }
          replaceDialogField(spec);
        }
        appField.addEventListener('change', syncAppValue);
        syncAppValue();
      }).catch(function (error) { notice(registryUi.notice, error.message, true); });
    }
  }

  dialog.form.addEventListener('submit', function (event) {
    event.preventDefault();
    if (!event.submitter || event.submitter.value === 'cancel') { dialog.node.close(); return; }
    /* A read-only dialog has no action; its primary button simply closes it. */
    if (typeof dialogAction !== 'function') { dialog.node.close(); return; }
    if (!dialog.form.reportValidity()) { return; }
    Promise.resolve(dialogAction(formValues())).catch(function (error) { dialog.error.textContent = error.message; dialog.error.hidden = false; });
  });
  // Confirm refreshes visibly even when no data changed.
  document.querySelector('[data-tasks-action="refresh"]').addEventListener('click', function () {
    var d = new Date();
    var h = ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) +
            ':' + ('0' + d.getSeconds()).slice(-2);
    Promise.resolve(loadTasks()).then(function () {
      notice(taskUi.notice, 'Updated ' + h + '.', false);
    });
  });
  document.querySelector('[data-tasks-action="create"]').addEventListener('click', createTask);
  document.querySelectorAll('[data-task-filter]').forEach(function (button) {
    button.addEventListener('click', function () {
      taskState.filter = button.dataset.taskFilter;
      document.querySelectorAll('[data-task-filter]').forEach(function (other) { other.setAttribute('aria-pressed', other === button ? 'true' : 'false'); });
      loadTasks();
    });
  });
  taskUi.team.addEventListener('change', function () { taskState.team = taskUi.team.value; loadTasks(); });
  taskUi.search.addEventListener('input', function () { taskState.search = taskUi.search.value.trim(); renderTaskList(); });
  taskUi.list.addEventListener('click', function (event) { var card = event.target.closest('[data-task-id]'); if (card) { taskState.selected = Number(card.dataset.taskId); renderTaskList(); renderTaskDetail(); loadTaskDetail(taskState.selected); } });
  taskUi.detail.addEventListener('click', function (event) { var button = event.target.closest('[data-task-action]'); if (button) { taskAction(button.dataset.taskAction); } });
  document.querySelector('[data-registry-action="refresh"]').addEventListener('click', function () {
    var d = new Date();
    var h = ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) +
            ':' + ('0' + d.getSeconds()).slice(-2);
    Promise.resolve(loadRegistries()).then(function () {
      notice(registryUi.notice, 'Updated ' + h + '.', false);
    });
  });
  document.querySelector('[data-registry-action="create"]').addEventListener('click', createRegistry);
  document.querySelectorAll('[data-registry]').forEach(function (button) {
    button.addEventListener('click', function () {
      registryState.kind = button.dataset.registry;
      document.querySelectorAll('[data-registry]').forEach(function (other) { other.setAttribute('aria-selected', other === button ? 'true' : 'false'); });
      renderRegistry();
      // Load the newly opened registry now, not when entering the screen.
      if (!hasRegistry(registryState.kind) && !isRegistryLoading(registryState.kind)) { loadRegistry(registryState.kind); }
    });
  });
  registryUi.search.addEventListener('input', function () { registryState.search = registryUi.search.value.trim(); renderRegistry(); });
  registryUi.grid.addEventListener('click', function (event) {
    var button = event.target.closest('[data-registry-name]');
    if (button) { editRegistry(registryState.kind, button.dataset.registryName, button.dataset.taskAction); }
  });
  // Relationship controls live inside the dialog, so delegate their events there.
  dialog.node.addEventListener('click', function (event) {
    // Move from a team record to one of its app records through the Apps tab.
    var appLink = event.target.closest('[data-open-app]');
    if (appLink) {
      var appName = appLink.dataset.openApp;
      dialog.node.close();
      var tab = document.querySelector('[data-registry="apps"]');
      if (tab) { tab.click(); }
      var openApp = function () { editRegistry('apps', appName, 'edit'); };
      if (hasRegistry('apps')) { openApp(); } else { loadRegistry('apps').then(openApp).catch(function () {}); }
      return;
    }
    var assignmentButton = event.target.closest('[data-relationship-action]');
    if (assignmentButton) {
      // Close the detail before opening its assignment dialog.
      var requestedAction = assignmentButton.dataset.relationshipAction;
      var targetName = assignmentButton.dataset.relationshipName;
      var kind = assignmentButton.dataset.relationshipKind || registryState.kind;
      dialog.node.close();
      editRegistry(kind, targetName, requestedAction);
      return;
    }
    var removeButton = event.target.closest('[data-unproject-app]');
    if (!removeButton) { return; }
    var app = removeButton.dataset.unprojectApp;
    var project = removeButton.dataset.unprojectProject;
    openDialog({title: 'Remove ' + app + ' from ' + project, kicker: 'Unassign', helpRoute: 'POST /api/app/<name>/unproject',
      help: 'The app and project continue to exist; only their relationship is removed. Enter the project name to confirm.', danger: true, submit: 'Remove',
      fields: [{name: 'confirm', label: 'Project name', required: true}],
      action: function (v) {
        if (v.confirm !== project) { return Promise.reject(new Error('The name does not match.')); }
        return mutate('/api/app/' + pathPart(app) + '/unproject', {project: project}, function () {
          dialog.node.close();
          return loadRegistry('apps');
        }, registryUi.notice);
      }});
  });
  document.querySelector('[data-message-action="create"]').addEventListener('click', openMessage);
  window.addEventListener('pizarra:help', function () {
    if (dialog.node.open) { setDialogHelp(dialogHelp.route, dialogHelp.fallback); }
  });
  window.addEventListener('pizarra:view', function (event) {
    if (event.detail.name === 'tasks' && !taskState.loaded && !taskState.loading) { loadTasks(); }
    if (event.detail.name === 'structure' && !hasRegistry(registryState.kind) && !isRegistryLoading(registryState.kind)) {
      loadRegistry(registryState.kind);
    }
  });
  if (!taskUi.view.hidden) { loadTasks(); }
  if (!registryUi.view.hidden) { loadRegistry(registryState.kind); }
})();
