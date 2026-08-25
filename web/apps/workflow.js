// Visual workflow editor. The graph is built only from the structured workflow
// card; dependencies are never inferred from presentation text and every edit
// changes exactly one hub concept.
(function () {
  'use strict';

  var state = {
    loaded: false,
    loading: false,
    list: [],
    selected: '',
    workflow: null,
    teams: [],
    groups: [],
    critical: [],
    dialogAction: null
  };
  var dialogHelp = {route: '', fallback: ''};

  // Keep the visible editor equal to the routes the running server actually
  // dispatches. These switches are deliberately local and explicit: a button
  // that only produces a 404 is not a feature preview, it is a false promise.
  var workflowRoutes = {
    editStep: true,
    removeStep: true,
    undo: true
  };

  var ui = {
    view: document.querySelector('[data-app-view="workflows"]'),
    list: document.getElementById('workflow-list'),
    listLoading: document.getElementById('workflow-list-loading'),
    listEmpty: document.getElementById('workflow-list-empty'),
    count: document.getElementById('workflow-count'),
    search: document.getElementById('workflow-search'),
    refresh: document.getElementById('workflow-refresh'),
    create: document.getElementById('workflow-create'),
    welcome: document.getElementById('workflow-welcome'),
    welcomeTitle: document.getElementById('workflow-welcome-title'),
    welcomeBody: document.getElementById('workflow-welcome-body'),
    detail: document.getElementById('workflow-detail'),
    name: document.getElementById('workflow-name'),
    group: document.getElementById('workflow-group'),
    wfState: document.getElementById('workflow-state'),
    summary: document.getElementById('workflow-summary'),
    blocker: document.getElementById('workflow-blocker'),
    blockerDetail: document.getElementById('workflow-blocker-detail'),
    caption: document.getElementById('workflow-canvas-caption'),
    columns: document.getElementById('workflow-columns'),
    edges: document.getElementById('workflow-edges'),
    canvas: document.getElementById('workflow-canvas'),
    scroll: document.getElementById('workflow-scroll'),
    fit: document.getElementById('workflow-fit'),
    commands: document.getElementById('workflow-command-bar'),
    notice: document.getElementById('workflow-notice'),
    noticeTitle: document.getElementById('workflow-notice-title'),
    noticeBody: document.getElementById('workflow-notice-body'),
    dialog: document.getElementById('workflow-dialog'),
    form: document.getElementById('workflow-form'),
    dialogKicker: document.getElementById('workflow-dialog-kicker'),
    dialogTitle: document.getElementById('workflow-dialog-title'),
    dialogHelp: document.getElementById('workflow-dialog-help'),
    dialogWarning: document.getElementById('workflow-dialog-warning'),
    fields: document.getElementById('workflow-form-fields'),
    formError: document.getElementById('workflow-form-error'),
    submit: document.getElementById('workflow-submit')
  };

  function element(tag, className, text) {
    var node = document.createElement(tag);
    if (className) {
      node.className = className;
    }
    if (text !== undefined) {
      node.textContent = text;
    }
    return node;
  }

  function object(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  function own(value, key) {
    return Object.prototype.hasOwnProperty.call(value, key);
  }

  function apiPath(name) {
    return encodeURIComponent(name);
  }

  function messageOf(payload, fallback) {
    if (object(payload) && typeof payload.error === 'string' && payload.error) {
      return payload.error + (payload.outcome === 'unknown' ?
        ' · Unknown outcome: DO NOT repeat the operation; reload and compare.' :
        (typeof payload.fix === 'string' && payload.fix ? ' · ' + payload.fix : ''));
    }
    return fallback;
  }

  function request(path, options) {
    var init = options || {};
    return fetch(path, init).then(function (response) {
      return response.json().catch(function () {
        throw new Error('The server returned invalid JSON.');
      }).then(function (payload) {
        if (!response.ok || !object(payload) || payload.ok !== true) {
          var error = new Error(messageOf(payload, 'The request was rejected (' + response.status + ').'));
          error.outcome = object(payload) && typeof payload.outcome === 'string' ? payload.outcome : '';
          throw error;
        }
        if (!own(payload, 'data')) {
          throw new Error('The response does not contain the contract\'s data field.');
        }
        return {data: payload.data, outcome: payload.outcome || 'applied', fix: payload.fix || ''};
      });
    });
  }

  function post(path, body) {
    return request(path, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Pizarra': '1'
      },
      body: JSON.stringify(body)
    });
  }

  function showNotice(kind, title, body) {
    ui.notice.className = 'workflow-notice' + (kind === 'error' ? ' workflow-notice--error' : '');
    ui.noticeTitle.textContent = title;
    ui.noticeBody.textContent = body;
    ui.notice.hidden = false;
  }

  function hideNotice() {
    ui.notice.hidden = true;
  }

  function validSummary(item) {
    return object(item) && typeof item.name === 'string' && item.name.length > 0 &&
      typeof item.group === 'string' && typeof item.state === 'string' &&
      Number.isSafeInteger(item.done) && Number.isSafeInteger(item.steps);
  }

  function validStep(step) {
    return object(step) && Number.isSafeInteger(step.n) && step.n > 0 &&
      Number.isSafeInteger(step.uid) && typeof step.title === 'string' &&
      typeof step.team === 'string' && typeof step.state === 'string' &&
      Number.isSafeInteger(step.eta) && step.eta >= -1 &&
      Array.isArray(step.deps) && step.deps.every(function (dep) {
        return Number.isSafeInteger(dep) && dep > 0;
      }) && (!own(step, 'xdeps') || (Array.isArray(step.xdeps) && step.xdeps.every(function (dep) {
        return object(dep) && typeof dep.wf === 'string' && dep.wf.length > 0 &&
          Number.isSafeInteger(dep.n) && dep.n > 0;
      }))) && Number.isSafeInteger(step.task);
  }

  function validWorkflow(wf) {
    return object(wf) && typeof wf.name === 'string' && wf.name.length > 0 &&
      typeof wf.group === 'string' && typeof wf.state === 'string' &&
      typeof wf.strict === 'boolean' && Number.isSafeInteger(wf.etadef) && wf.etadef >= -1 &&
      Array.isArray(wf.steps) &&
      wf.steps.every(validStep);
  }

  function unwrapWorkflow(data) {
    if (!object(data) || !validWorkflow(data.workflow)) {
      throw new Error('The workflow record does not match the agreed format.');
    }
    return data.workflow;
  }

  function renderListStatus() {
    ui.list.setAttribute('aria-busy', state.loading ? 'true' : 'false');
    ui.listLoading.hidden = state.loaded || !state.loading;
    if (!state.loaded) {
      ui.count.textContent = '—';
      ui.listEmpty.hidden = true;
      ui.welcomeTitle.textContent = state.loading ? 'Loading workflows…' : 'Workflows could not be loaded';
      ui.welcomeBody.textContent = state.loading ? 'Waiting for the hub.' : 'Review the warning and try again.';
    }
  }

  function loadLists(propagate) {
    state.loading = true;
    renderListStatus();
    hideNotice();
    return Promise.all([
      request('/api/workflows'),
      request('/api/teams'),
      request('/api/groups')
    ]).then(function (results) {
      var workflows = results[0].data;
      var teams = results[1].data;
      var groups = results[2].data;
      if (!object(workflows) || !Array.isArray(workflows.workflows) ||
          !workflows.workflows.every(validSummary)) {
        throw new Error('The workflow list does not match the contract.');
      }
      if (!object(teams) || !Array.isArray(teams.teams) ||
          !object(groups) || !Array.isArray(groups.groups)) {
        throw new Error('Teams and groups could not be validated for the editor.');
      }
      state.list = workflows.workflows.slice().sort(function (a, b) {
        return a.name.localeCompare(b.name, 'en');
      });
      state.teams = teams.teams.filter(function (team) {
        return object(team) && typeof team.name === 'string';
      }).map(function (team) { return team.name; });
      state.groups = groups.groups.filter(function (group) {
        return object(group) && typeof group.name === 'string';
      }).map(function (group) { return group.name; });
      state.loaded = true;
      renderList();
      // Load a full workflow only after selection. If one is already selected,
      // refresh that record instead of fetching an arbitrary first entry.
      if (state.selected && state.list.some(function (item) { return item.name === state.selected; })) {
        return loadWorkflow(state.selected, propagate === true);
      }
      state.selected = '';
      state.workflow = null;
      renderWelcome();
      return null;
    }).catch(function (error) {
      showNotice('error', 'The map could not be opened.', error.message);
      if (propagate === true) { throw error; }
    }).finally(function () {
      state.loading = false;
      renderListStatus();
    });
  }

  function renderList() {
    var term = ui.search.value.trim().toLocaleLowerCase('en');
    var visible = state.list.filter(function (item) {
      return !term || item.name.toLocaleLowerCase('en').indexOf(term) >= 0 ||
        item.group.toLocaleLowerCase('en').indexOf(term) >= 0;
    });
    ui.list.replaceChildren();
    ui.count.textContent = state.loaded ? String(state.list.length) : '—';
    visible.forEach(function (item) {
      var button = element('button', 'workflow-list-item');
      var progress = element('span', 'workflow-list-item__progress');
      var bar = element('i');
      var percentage = item.steps > 0 ? Math.round(item.done * 100 / item.steps) : 0;
      button.type = 'button';
      button.dataset.workflowName = item.name;
      button.setAttribute('role', 'option');
      button.setAttribute('aria-selected', item.name === state.selected ? 'true' : 'false');
      button.appendChild(element('strong', '', item.name));
      button.appendChild(element('small', '', item.state));
      button.appendChild(element('small', '', '@' + item.group + ' · ' + item.done + '/' + item.steps));
      bar.style.width = percentage + '%';
      progress.appendChild(bar);
      button.appendChild(progress);
      ui.list.appendChild(button);
    });
    ui.listEmpty.hidden = !state.loaded || state.list.length !== 0 || term !== '';
    renderListStatus();
  }

  function loadWorkflow(name, propagate) {
    state.selected = name;
    renderList();
    return request('/api/workflow/' + apiPath(name)).then(function (result) {
      state.workflow = unwrapWorkflow(result.data);
      renderWorkflow();
    }).catch(function (error) {
      showNotice('error', 'Could not load ' + name + '.', error.message);
      if (propagate === true) { throw error; }
    });
  }

  function finished(step) {
    return step.state.toLocaleLowerCase('en') === 'done';
  }

  function graphOf(wf) {
    var byId = new Map();
    var children = new Map();
    var levels = new Map();
    var visiting = new Set();
    wf.steps.forEach(function (step) {
      byId.set(step.n, step);
      children.set(step.n, []);
    });
    wf.steps.forEach(function (step) {
      step.deps.forEach(function (dep) {
        if (children.has(dep)) {
          children.get(dep).push(step.n);
        }
      });
    });

    function levelOf(id) {
      var step = byId.get(id);
      var best = 0;
      if (levels.has(id)) {
        return levels.get(id);
      }
      if (!step || visiting.has(id)) {
        return 0;
      }
      visiting.add(id);
      step.deps.forEach(function (dep) {
        if (byId.has(dep)) {
          best = Math.max(best, levelOf(dep) + 1);
        }
      });
      visiting.delete(id);
      levels.set(id, best);
      return best;
    }

    wf.steps.forEach(function (step) { levelOf(step.n); });

    var reachMemo = new Map();
    function reach(id, trail) {
      var result = new Set();
      var seen = trail || new Set();
      if (seen.has(id)) {
        return result;
      }
      seen.add(id);
      (children.get(id) || []).forEach(function (child) {
        var childStep = byId.get(child);
        if (childStep && !finished(childStep)) {
          result.add(child);
          reach(child, new Set(seen)).forEach(function (n) { result.add(n); });
        }
      });
      return result;
    }
    wf.steps.forEach(function (step) { reachMemo.set(step.n, reach(step.n)); });

    var longestMemo = new Map();
    function longest(id, trail) {
      var best = [];
      var seen = trail || new Set();
      if (seen.has(id)) {
        return [];
      }
      seen.add(id);
      (children.get(id) || []).forEach(function (child) {
        var childStep = byId.get(child);
        var candidate;
        if (!childStep || finished(childStep)) {
          return;
        }
        candidate = longest(child, new Set(seen));
        if (candidate.length > best.length ||
            (candidate.length === best.length && candidate[0] < best[0])) {
          best = candidate;
        }
      });
      return [id].concat(best);
    }

    var candidates = wf.steps.filter(function (step) {
      if (finished(step)) {
        return false;
      }
      return step.deps.every(function (dep) {
        return !byId.has(dep) || finished(byId.get(dep));
      });
    });
    if (candidates.length === 0) {
      candidates = wf.steps.filter(function (step) { return !finished(step); });
    }
    candidates.forEach(function (step) { longestMemo.set(step.n, longest(step.n)); });
    // A milestone with cross-workflow dependencies is not safely available
    // from this record alone. Prefer candidates without external waits and
    // disclose any unavoidable cross-workflow dependency in the detail.
    function externalDependencyCount(step) { return (step.xdeps || []).length; }
    candidates.sort(function (a, b) {
      var extDiff = (externalDependencyCount(a) ? 1 : 0) - (externalDependencyCount(b) ? 1 : 0);
      var reachDiff = reachMemo.get(b.n).size - reachMemo.get(a.n).size;
      var pathDiff = longestMemo.get(b.n).length - longestMemo.get(a.n).length;
      return extDiff || reachDiff || pathDiff || a.n - b.n;
    });

    return {
      byId: byId,
      children: children,
      levels: levels,
      critical: candidates.length ? longestMemo.get(candidates[0].n) : [],
      blocker: candidates.length ? candidates[0] : null,
      blocked: candidates.length ? reachMemo.get(candidates[0].n).size : 0
    };
  }

  function renderWelcome() {
    ui.welcome.hidden = false;
    ui.detail.hidden = true;
    ui.welcomeTitle.textContent = 'Choose a workflow';
    ui.welcomeBody.textContent = 'Each milestone appears as a node and each dependency as an actual connection.';
  }

  function stateLabel(value) {
    var labels = {
      draft: 'Draft', running: 'Running', halted: 'Halted',
      done: 'Complete', aborted: 'Aborted', active: 'Active',
      pending: 'Pending', error: 'Error', fixed: 'Fixed', waiting: 'Waiting'
    };
    return labels[value.toLocaleLowerCase('en')] || value;
  }

  function initials(name) {
    return name.split(/[._-]/).filter(Boolean).slice(0, 2).map(function (part) {
      return part.charAt(0);
    }).join('').toLocaleUpperCase('en') || '?';
  }

  function etaLabel(value) {
    if (value < 0) { return 'no deadline'; }
    if (value === 0) { return 'inherited deadline'; }
    if (value % 86400 === 0) { return 'deadline ' + (value / 86400) + 'd'; }
    if (value % 3600 === 0) { return 'deadline ' + (value / 3600) + 'h'; }
    if (value % 60 === 0) { return 'deadline ' + (value / 60) + 'm'; }
    return 'deadline ' + value + 's';
  }

  function actionButton(label, action, step, primary) {
    var button = element('button', 'node-action' + (primary ? ' node-action--primary' : ''), label);
    button.type = 'button';
    button.dataset.nodeAction = action;
    button.dataset.step = String(step.n);
    return button;
  }

  function renderNode(step, critical) {
    var status = step.state.toLocaleLowerCase('en');
    var node = element('article', 'workflow-node workflow-node--' + status + (critical ? ' workflow-node--critical' : ''));
    var top = element('div', 'workflow-node__top');
    var owner = element('p', 'workflow-node__owner');
    var meta = element('div', 'workflow-node__meta');
    var actions = element('div', 'workflow-node__actions');
    node.dataset.step = String(step.n);
    top.appendChild(element('span', 'workflow-node__number', '#' + step.n));
    top.appendChild(element('span', 'workflow-node__state', stateLabel(step.state)));
    node.appendChild(top);
    node.appendChild(element('h3', '', step.title));
    owner.appendChild(element('i', '', initials(step.team)));
    owner.appendChild(element('span', '', step.team || 'No owner'));
    node.appendChild(owner);
    var dependencyLabels = step.deps.map(function (n) { return '#' + n; }).concat((step.xdeps || []).map(function (dep) {
      return dep.wf + '#' + dep.n;
    }));
    meta.appendChild(element('span', '', dependencyLabels.length ? 'depends on ' + dependencyLabels.join(', ') : 'root'));
    meta.appendChild(element('span', '', etaLabel(step.eta)));
    if (step.task > 0) {
      meta.appendChild(element('span', '', 'task #' + step.task));
    }
    if (critical) {
      meta.appendChild(element('span', '', 'critical path'));
    }
    node.appendChild(meta);

    if (state.workflow && state.workflow.state === 'draft') {
      if (workflowRoutes.editStep) {
        actions.appendChild(actionButton('Edit', 'edit', step, false));
      }
      actions.appendChild(actionButton('Insert', 'insert', step, true));
      if (workflowRoutes.removeStep) {
        actions.appendChild(actionButton('Remove', 'remove', step, false));
      }
    } else if (status === 'active') {
      actions.appendChild(actionButton('Complete', 'done', step, true));
      actions.appendChild(actionButton('Report failure', 'error', step, false));
    } else if (status === 'error') {
      actions.appendChild(actionButton('Mark fixed', 'fixed', step, true));
    }
    if (state.workflow && state.workflow.state !== 'draft' &&
        state.workflow.state !== 'done' && state.workflow.state !== 'aborted' &&
        workflowRoutes.editStep) {
      actions.appendChild(actionButton('Deadline', 'eta', step, false));
    }
    if (actions.childElementCount > 0) {
      node.appendChild(actions);
    }
    return node;
  }

  function renderCommands(wf) {
    function command(action, label, className) {
      var button = ui.commands.querySelector('[data-workflow-action="' + action + '"]');
      if (!button) {
        button = element('button', className || 'button button--quiet', label);
        button.type = 'button';
        button.dataset.workflowAction = action;
        ui.commands.appendChild(button);
      }
      return button;
    }
    Array.prototype.forEach.call(ui.commands.querySelectorAll('[data-workflow-action]'), function (button) {
      var action = button.dataset.workflowAction;
      button.hidden = true;
      if (action === 'start') {
        button.hidden = wf.state !== 'draft';
      } else if (action === 'abort') {
        button.hidden = wf.state === 'done' || wf.state === 'aborted';
      } else if (action === 'undo') {
        button.hidden = !workflowRoutes.undo;
      }
    });
    var appendButton = ui.commands.querySelector('[data-workflow-action="append"]');
    if (!appendButton) {
      appendButton = element('button', 'button button--quiet', 'Add milestone');
      appendButton.type = 'button';
      appendButton.dataset.workflowAction = 'append';
      ui.commands.appendChild(appendButton);
    }
    appendButton.hidden = wf.state !== 'draft';
    command('settings', 'Settings').hidden = wf.state === 'done' || wf.state === 'aborted';
    command('clone', 'Clone').hidden = false;
    command('verify', 'Verify', 'button button--primary').hidden = !wf.steps.some(function (step) {
      return step.state.toLocaleLowerCase('en') === 'fixed';
    });
    var deleteButton = ui.commands.querySelector('[data-workflow-action="delete"]');
    if (!deleteButton) {
      deleteButton = element('button', 'button button--danger-quiet', 'Delete');
      deleteButton.type = 'button';
      deleteButton.dataset.workflowAction = 'delete';
      ui.commands.prepend(deleteButton);
    }
  }

  function renderWorkflow() {
    var wf = state.workflow;
    var graph;
    var maxLevel = 0;
    var criticalSet;
    var done;
    if (!wf) {
      renderWelcome();
      return;
    }
    graph = graphOf(wf);
    state.critical = graph.critical;
    criticalSet = new Set(graph.critical);
    done = wf.steps.filter(finished).length;
    ui.welcome.hidden = true;
    ui.detail.hidden = false;
    ui.name.textContent = wf.name;
    ui.group.textContent = '@' + wf.group;
    ui.wfState.className = 'state-badge state-badge--' + wf.state.toLocaleLowerCase('en');
    ui.wfState.textContent = stateLabel(wf.state);
    ui.summary.textContent = done + ' of ' + wf.steps.length + ' milestones complete' + (wf.strict ? ' · strict mode' : '');
    ui.caption.textContent = wf.steps.length + ' nodes · ' + wf.steps.reduce(function (sum, step) {
      return sum + step.deps.length + (step.xdeps || []).length;
    }, 0) + ' dependencies';
    if (graph.blocker) {
      ui.blocker.textContent = '#' + graph.blocker.n + ' · ' + graph.blocker.title;
      ui.blockerDetail.textContent = graph.blocked === 0 ?
        'This is the next structurally available milestone.' :
        'Its progress directly or indirectly unlocks ' + graph.blocked + ' milestone' + (graph.blocked === 1 ? '' : 's') +
        ' that ' + (graph.blocked === 1 ? 'is' : 'are') + ' pending.';
      // Make cross-workflow waits explicit because the hub will not activate
      // this milestone until the external dependency completes.
      if ((graph.blocker.xdeps || []).length) {
        ui.blockerDetail.textContent += ' First, ' +
          graph.blocker.xdeps.map(function (dep) { return dep.wf + '#' + dep.n; }).join(', ') +
          ' (another plan) must finish; the hub will not activate it until then.';
      }
    } else {
      ui.blocker.textContent = wf.steps.length ? 'No pending work remains' : 'The draft does not have any milestones yet';
      ui.blockerDetail.textContent = wf.steps.length ? 'The visible structure is complete.' : 'Add the first node to begin the map.';
    }
    renderCommands(wf);
    ui.columns.replaceChildren();
    wf.steps.forEach(function (step) {
      maxLevel = Math.max(maxLevel, graph.levels.get(step.n) || 0);
    });
    for (var level = 0; level <= maxLevel; level += 1) {
      var column = element('section', 'workflow-column');
      column.dataset.level = String(level);
      column.appendChild(element('span', 'workflow-column__label', level === 0 ? 'Start' : 'Level ' + (level + 1)));
      wf.steps.filter(function (step) {
        return (graph.levels.get(step.n) || 0) === level;
      }).sort(function (a, b) { return a.n - b.n; }).forEach(function (step) {
        column.appendChild(renderNode(step, criticalSet.has(step.n)));
      });
      ui.columns.appendChild(column);
    }
    requestAnimationFrame(function () {
      requestAnimationFrame(drawEdges);
    });
  }

  function svgNode(tag, className) {
    var node = document.createElementNS('http://www.w3.org/2000/svg', tag);
    node.setAttribute('class', className);
    return node;
  }

  function drawEdges() {
    var wf = state.workflow;
    var canvasRect;
    var criticalEdges = new Set();
    if (!wf || ui.detail.hidden) {
      return;
    }
    // Read all node geometry before writing SVG paths. This avoids repeated
    // layout work and commits every edge in one fragment replacement.
    var nodes = ui.columns.querySelectorAll('[data-step]');
    var rects = new Map();
    var i;
    for (i = 0; i < nodes.length; i += 1) {
      rects.set(Number(nodes[i].dataset.step), nodes[i].getBoundingClientRect());
    }
    ui.edges.setAttribute('width', String(ui.canvas.scrollWidth));
    ui.edges.setAttribute('height', String(ui.canvas.scrollHeight));
    ui.edges.setAttribute('viewBox', '0 0 ' + ui.canvas.scrollWidth + ' ' + ui.canvas.scrollHeight);
    canvasRect = ui.canvas.getBoundingClientRect();
    for (i = 1; i < state.critical.length; i += 1) {
      criticalEdges.add(state.critical[i - 1] + ':' + state.critical[i]);
    }
    var frag = document.createDocumentFragment();
    wf.steps.forEach(function (step) {
      step.deps.forEach(function (dep) {
        var sourceRect = rects.get(dep);
        var targetRect = rects.get(step.n);
        var x1;
        var y1;
        var x2;
        var y2;
        var bend;
        var path;
        var dot;
        var isCritical = criticalEdges.has(dep + ':' + step.n);
        if (!sourceRect || !targetRect) {
          return;
        }
        x1 = sourceRect.right - canvasRect.left;
        y1 = sourceRect.top + sourceRect.height / 2 - canvasRect.top;
        x2 = targetRect.left - canvasRect.left;
        y2 = targetRect.top + targetRect.height / 2 - canvasRect.top;
        bend = Math.max(24, (x2 - x1) * .48);
        path = svgNode('path', 'workflow-edge' + (isCritical ? ' workflow-edge--critical' : ''));
        path.setAttribute('d', 'M ' + x1 + ' ' + y1 + ' C ' + (x1 + bend) + ' ' + y1 + ', ' + (x2 - bend) + ' ' + y2 + ', ' + x2 + ' ' + y2);
        frag.appendChild(path);
        dot = svgNode('circle', 'workflow-edge-dot' + (isCritical ? ' workflow-edge-dot--critical' : ''));
        dot.setAttribute('cx', String(x2));
        dot.setAttribute('cy', String(y2));
        dot.setAttribute('r', isCritical ? '4' : '3');
        frag.appendChild(dot);
      });
    });
    ui.edges.replaceChildren(frag);
  }

  function field(spec) {
    var label = element('label', 'editor-field');
    var control;
    label.appendChild(element('span', '', spec.label));
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
    if (spec.maxLength) {
      control.maxLength = spec.maxLength;
    }
    if (spec.placeholder) {
      control.placeholder = spec.placeholder;
    }
    label.appendChild(control);
    if (spec.help) {
      label.appendChild(element('small', '', spec.help));
    }
    return label;
  }

  function setDialogHelp(route, fallback) {
    var help = window.PizarraHelp ? window.PizarraHelp.forRoute(route || '', fallback || '') : {text: fallback || '', warning: ''};
    dialogHelp = {route: route || '', fallback: fallback || ''};
    ui.dialogHelp.textContent = help.text;
    ui.dialogWarning.textContent = help.warning ? 'Warning: ' + help.warning : '';
    ui.dialogWarning.hidden = !help.warning;
  }

  function openDialog(config) {
    state.dialogAction = config.action;
    ui.dialogKicker.textContent = config.kicker || 'Edit workflow';
    ui.dialogTitle.textContent = config.title;
    setDialogHelp(config.helpRoute || '', config.help || '');
    ui.submit.textContent = config.submit || 'Save';
    ui.submit.className = 'button ' + (config.danger ? 'button--danger-quiet' : 'button--primary');
    ui.fields.replaceChildren();
    (config.fields || []).forEach(function (spec) { ui.fields.appendChild(field(spec)); });
    ui.formError.hidden = true;
    ui.formError.textContent = '';
    ui.dialog.showModal();
    var first = ui.fields.querySelector('input,select,textarea');
    if (first) {
      first.focus();
    }
  }

  function replaceDialogField(spec) {
    var current = ui.form.elements.namedItem(spec.name);
    var replacement;
    if (!current) { return null; }
    replacement = field(spec);
    current.closest('.editor-field').replaceWith(replacement);
    return ui.form.elements.namedItem(spec.name);
  }

  function dependencyValue(step) {
    return step.deps.map(String).concat((step.xdeps || []).map(function (dep) {
      return dep.wf + '#' + dep.n;
    })).join(',');
  }

  function valuesOfForm() {
    var values = {};
    new FormData(ui.form).forEach(function (value, key) {
      values[key] = String(value);
    });
    return values;
  }

  function applyMutation(path, body, removed, followReturned) {
    ui.submit.disabled = true;
    ui.formError.hidden = true;
    return post(path, body).then(function (result) {
      ui.dialog.close();
      if (removed) {
        state.selected = '';
        state.workflow = null;
        showNotice('ok', 'Workflow deleted.', removed + ' is no longer part of the registry.');
        return loadLists();
      }
      if (result.outcome === 'applied_stale' || result.data === null) {
        showNotice('ok', 'Change applied; the view is stale.', result.fix || 'Refresh to read the confirmed record.');
        return loadLists();
      }
      state.workflow = unwrapWorkflow(result.data);
      if (followReturned) {
        state.selected = state.workflow.name;
      }
      renderWorkflow();
      showNotice('ok', 'Change applied.', 'The map was redrawn from the record returned by the same command.');
      return refreshSummary().catch(function (summaryError) {
        /* The returned workflow card proves the mutation was applied. A
           secondary list refresh cannot turn that success into a rejection:
           saying so would invite a duplicate retry while hiding the warning
           inside the dialog that was already closed. */
        showNotice('error', 'Change applied; summary not refreshed.',
          'The map contains the confirmed result. DO NOT repeat the operation. ' +
          'The sidebar list could not be refreshed: ' + summaryError.message);
      });
    }).catch(function (error) {
      var reconcile = error.outcome === 'unknown' ? loadLists(true) : Promise.resolve();
      return reconcile.then(function () {
        ui.formError.textContent = error.message + (error.outcome === 'unknown' ?
          ' · The map was reloaded so you can compare the actual state.' : '');
        ui.formError.hidden = false;
      }, function (reloadError) {
        ui.formError.textContent = error.message + ' · Could not reload for comparison: ' + reloadError.message;
        ui.formError.hidden = false;
      });
    }).finally(function () {
      ui.submit.disabled = false;
    });
  }

  function refreshSummary() {
    return request('/api/workflows').then(function (result) {
      if (object(result.data) && Array.isArray(result.data.workflows) && result.data.workflows.every(validSummary)) {
        state.list = result.data.workflows.slice().sort(function (a, b) { return a.name.localeCompare(b.name, 'en'); });
        renderList();
      }
    });
  }

  function submitConfig(config) {
    openDialog(config);
  }

  function currentStep(number) {
    return state.workflow ? state.workflow.steps.find(function (step) { return step.n === number; }) : null;
  }

  function nodeAction(action, step) {
    var name = state.workflow.name;
    if (action === 'insert') {
      submitConfig({
        title: 'Insert after #' + step.n,
        helpRoute: 'POST /api/workflow/<name>/insert',
        help: 'The new node is placed between this milestone and all its dependents. No other dependency is changed.',
        submit: 'Insert node',
        fields: [
          {name: 'milestone', label: 'Milestone', required: true, maxLength: 120, placeholder: 'What must be completed'},
          {name: 'team', label: 'Owner', type: 'select', value: step.team, options: state.teams.concat(['console'])},
          {name: 'eta', label: 'Optional deadline', placeholder: '45m, 4h, 2d…', help: 'An empty value keeps the default deadline.'}
        ],
        action: function (v) {
          return applyMutation('/api/workflow/' + apiPath(name) + '/insert', {
            milestone: v.milestone, team: v.team, after: step.n, eta: v.eta
          });
        }
      });
    } else if (action === 'edit') {
      submitConfig({
        title: 'Edit node #' + step.n,
        helpRoute: 'POST /api/workflow/<name>/step/<n>/set',
        help: 'One command changes one field. Current dependencies are shown in full and are never reordered silently.',
        fields: [
          {name: 'field', label: 'Field', type: 'select', options: [
            {value: 'milestone', label: 'Milestone text'},
            {value: 'team', label: 'Owner'},
            {value: 'after', label: 'Dependencies'},
            {value: 'eta', label: 'Deadline'}
          ]},
          {name: 'value', label: 'New value', required: true, value: step.title,
           help: 'For dependencies: the complete list (for example, 1,3 or another-plan#2). This replaces rather than appends.'}
        ],
        action: function (v) {
          return applyMutation('/api/workflow/' + apiPath(name) + '/step/' + step.n + '/set', v);
        }
      });
      var stepField = ui.form.elements.namedItem('field');
      function syncStepValue() {
        var selected = stepField.value;
        var spec = {name: 'value', label: 'Current / new value', required: true};
        if (selected === 'milestone') {
          spec.type = 'textarea';
          spec.value = step.title;
          spec.maxLength = 120;
          spec.help = 'Maximum 120 characters.';
        } else if (selected === 'team') {
          spec.type = 'select';
          spec.value = step.team;
          spec.options = state.teams.concat(['console']);
        } else if (selected === 'eta') {
          spec.value = step.eta < 0 ? 'off' : (step.eta === 0 ? 'inherit' : step.eta + 's');
          spec.placeholder = '45m, 4h, 2d, off, or inherit';
          spec.help = 'An empty value is not valid: use inherit to return to the plan-wide deadline.';
        } else {
          spec.value = dependencyValue(step);
          spec.help = 'Complete list (for example, 1,3 or another-plan#2). This replaces rather than appends.';
        }
        replaceDialogField(spec);
      }
      stepField.addEventListener('change', syncStepValue);
      syncStepValue();
    } else if (action === 'eta') {
      submitConfig({
        title: 'Deadline for node #' + step.n,
        helpRoute: 'POST /api/workflow/<name>/step/<n>/set',
        help: 'The deadline can be adjusted while the workflow is running. This does not change dependencies or state.',
        submit: 'Save deadline',
        fields: [{name: 'value', label: 'Current / new deadline', required: true,
          value: step.eta < 0 ? 'off' : (step.eta === 0 ? 'inherit' : step.eta + 's'),
          placeholder: '45m, 4h, 2d, off, or inherit',
          help: 'inherit uses the plan-wide deadline; off disables the warning for this node.'}],
        action: function (v) {
          return applyMutation('/api/workflow/' + apiPath(name) + '/step/' + step.n + '/set',
            {field: 'eta', value: v.value});
        }
      });
    } else if (action === 'remove') {
      submitConfig({
        title: 'Remove node #' + step.n,
        helpRoute: 'POST /api/workflow/<name>/step/<n>/remove',
        kicker: 'Destructive operation',
        help: 'Its dependents will inherit this node\'s exact dependencies, including those that point to other plans. The hub will reject the change if another workflow depends on it.',
        submit: 'Remove node',
        danger: true,
        fields: [{name: 'confirm', label: 'Enter the node number to confirm', required: true, placeholder: String(step.n)}],
        action: function (v) {
          if (v.confirm !== String(step.n)) {
            return Promise.reject(new Error('The confirmation number does not match.'));
          }
          return applyMutation('/api/workflow/' + apiPath(name) + '/step/' + step.n + '/remove', {});
        }
      });
    } else if (action === 'done') {
      submitConfig({
        title: 'Complete #' + step.n,
        helpRoute: 'POST /api/workflow/<name>/done',
        help: 'The evidence remains in the workflow record. This action may activate dependent nodes.',
        submit: 'Mark complete',
        fields: [{name: 'proof', label: 'Completion evidence', type: 'textarea', maxLength: 4096,
          placeholder: 'What was done and how it was verified', help: 'Maximum 4 KiB.'}],
        action: function (v) {
          return applyMutation('/api/workflow/' + apiPath(name) + '/done', {step: step.n, proof: v.proof});
        }
      });
    } else if (action === 'error') {
      submitConfig({
        title: 'Stop at #' + step.n,
        helpRoute: 'POST /api/workflow/<name>/error',
        kicker: 'Report a failure',
        help: 'The workflow stops so nobody builds on an incorrect result.',
        submit: 'Report failure',
        danger: true,
        fields: [{name: 'why', label: 'What failed', type: 'textarea', required: true, maxLength: 4096,
          help: 'Maximum 4 KiB.'}],
        action: function (v) {
          return applyMutation('/api/workflow/' + apiPath(name) + '/error', {step: step.n, why: v.why});
        }
      });
    } else if (action === 'fixed') {
      submitConfig({
        title: 'Mark #' + step.n + ' fixed',
        helpRoute: 'POST /api/workflow/<name>/fixed',
        help: 'Describe both the fix and its validation. A second party will have to verify it.',
        submit: 'Request verification',
        fields: [{name: 'text', label: 'Fix and evidence', type: 'textarea', required: true, maxLength: 4096,
          help: 'Maximum 4 KiB.'}],
        action: function (v) {
          return applyMutation('/api/workflow/' + apiPath(name) + '/fixed', v);
        }
      });
    }
  }

  function workflowAction(action) {
    var wf = state.workflow;
    if (!wf) {
      return;
    }
    if (action === 'start') {
      submitConfig({
        title: 'Start ' + wf.name,
        helpRoute: 'POST /api/workflow/<name>/start',
        help: 'The draft starts running and root nodes become active. The structure can no longer be edited freely.',
        submit: 'Start workflow',
        fields: [],
        action: function () { return applyMutation('/api/workflow/' + apiPath(wf.name) + '/start', {}); }
      });
    } else if (action === 'append') {
      submitConfig({
        title: wf.steps.length ? 'Add a milestone' : 'Create the first milestone',
        helpRoute: 'POST /api/workflow/<name>/step',
        help: wf.steps.length ?
          'Add a node without changing the dependencies of existing nodes. Provide the complete list only if this milestone depends on others.' :
          'The first node will be a root. You can then insert or add more nodes without starting the plan yet.',
        submit: 'Add milestone',
        fields: [
          {name: 'milestone', label: 'Milestone', required: true, maxLength: 120, placeholder: 'What must be completed'},
          {name: 'team', label: 'Owner', type: 'select', options: state.teams.concat(['console'])},
          {name: 'after', label: 'Optional dependencies', placeholder: '1,3 or another-plan#2', help: 'An empty value creates a root. The submitted list is exact.'},
          {name: 'eta', label: 'Optional deadline', placeholder: '45m, 4h, 2d…'}
        ],
        action: function (v) {
          return applyMutation('/api/workflow/' + apiPath(wf.name) + '/step', v);
        }
      });
    } else if (action === 'settings') {
      submitConfig({
        title: 'Settings for ' + wf.name,
        helpRoute: 'POST /api/workflow/<name>/set',
        help: 'Change one plan property. Dependencies and nodes are not touched.',
        fields: [
          {name: 'field', label: 'Property', type: 'select', options: [
            {value: 'strict', label: 'Strict mode'},
            {value: 'eta', label: 'Default deadline'}
          ]},
          {name: 'value', label: 'Current / new value', required: true, placeholder: '4h, 2d…'}
        ],
        action: function (v) {
          return applyMutation('/api/workflow/' + apiPath(wf.name) + '/set', v);
        }
      });
      var planField = ui.form.elements.namedItem('field');
      function syncPlanValue() {
        var selected = planField.value;
        var spec = {name: 'value', label: 'Current / new value', required: true};
        if (selected === 'strict') {
          spec.type = 'select';
          spec.value = wf.strict ? 'on' : 'off';
          spec.options = [{value: 'off', label: 'No'}, {value: 'on', label: 'Yes'}];
          spec.help = 'The screen shows Yes/No; the server receives on/off.';
        } else {
          spec.value = wf.etadef < 0 ? 'off' : (wf.etadef === 0 ? 'factory' : wf.etadef + 's');
          spec.placeholder = '4h, 2d, off, or factory';
        }
        replaceDialogField(spec);
      }
      planField.addEventListener('change', syncPlanValue);
      syncPlanValue();
    } else if (action === 'clone') {
      submitConfig({
        title: 'Clone ' + wf.name,
        helpRoute: 'POST /api/workflow/<name>/clone',
        help: 'Create another draft with the same structure. The original is unchanged.',
        submit: 'Create clone',
        fields: [
          {name: 'to', label: 'New workflow name', required: true, placeholder: wf.name + '-copy'},
          {name: 'group', label: 'Group', type: 'select', options:
            [{value: '', label: 'Keep @' + wf.group}].concat(state.groups)}
        ],
        action: function (v) {
          return applyMutation('/api/workflow/' + apiPath(wf.name) + '/clone', v, '', true);
        }
      });
    } else if (action === 'verify') {
      submitConfig({
        title: 'Verify the fix',
        helpRoute: 'POST /api/workflow/<name>/verify',
        help: 'Verification belongs to another person: confirm the observed result, not the intent of the fix.',
        submit: 'Record verification',
        fields: [
          {name: 'result', label: 'Result', type: 'select', options: [
            {value: 'ok', label: 'Correct'}, {value: 'fail', label: 'Still failing'}
          ]},
          {name: 'note', label: 'Verification note', type: 'textarea', maxLength: 4096,
            help: 'Maximum 4 KiB.'}
        ],
        action: function (v) {
          return applyMutation('/api/workflow/' + apiPath(wf.name) + '/verify', v);
        }
      });
    } else if (action === 'abort') {
      submitConfig({
        title: 'Abort ' + wf.name,
        helpRoute: 'POST /api/workflow/<name>/abort',
        kicker: 'Destructive operation',
        help: 'The work is not marked complete: linked tasks are canceled and the plan becomes aborted.',
        submit: 'Abort workflow',
        danger: true,
        fields: [{name: 'why', label: 'Reason', type: 'textarea', required: true, maxLength: 4096,
          help: 'Maximum 4 KiB.'}],
        action: function (v) { return applyMutation('/api/workflow/' + apiPath(wf.name) + '/abort', v); }
      });
    } else if (action === 'delete') {
      submitConfig({
        title: 'Delete ' + wf.name,
        helpRoute: 'POST /api/workflow/<name>/delete',
        kicker: 'Permanent deletion',
        help: 'Only a draft or a completed/aborted plan without external dependencies can be deleted. Its history is deleted as well.',
        submit: 'Delete permanently',
        danger: true,
        fields: [{name: 'confirm', label: 'Enter the full name to confirm', required: true}],
        action: function (v) {
          if (v.confirm !== wf.name) {
            return Promise.reject(new Error('The confirmation name does not match.'));
          }
          return applyMutation('/api/workflow/' + apiPath(wf.name) + '/delete', {}, wf.name);
        }
      });
    } else if (action === 'undo') {
      request('/api/workflow/' + apiPath(wf.name) + '/history').then(function (result) {
        var history = object(result.data) ? result.data.history : null;
        if (!Array.isArray(history) || !history.every(function (line) { return typeof line === 'string'; })) {
          throw new Error('The workflow history does not match the contract.');
        }
        var choices = [{value: '', label: 'Latest available change'}];
        history.forEach(function (line) {
          var match = /^snap\s+(\d+)\s+/.exec(line);
          if (match) { choices.push({value: match[1], label: line}); }
        });
        submitConfig({
          title: 'Navigate history for ' + wf.name,
          helpRoute: 'POST /api/workflow/<name>/undo',
          help: 'Choose an actual record point. Before restoration, the current state is also saved so you can move forward again.',
          submit: 'Restore this point',
          fields: [{name: 'snapshot', label: 'History point', type: 'select', options: choices}],
          action: function (v) {
            var body = {};
            if (v.snapshot) { body.snapshot = Number(v.snapshot); }
            return applyMutation('/api/workflow/' + apiPath(wf.name) + '/undo', body);
          }
        });
      }).catch(function (error) {
        showNotice('error', 'The history could not be read.', error.message);
      });
    }
  }

  function createWorkflow() {
    submitConfig({
      title: 'New workflow',
      helpRoute: 'POST /api/workflow',
      kicker: 'Create a work map',
      help: 'Create an empty draft. Then add its milestones without starting work yet.',
      submit: 'Create workflow',
      fields: [
        {name: 'name', label: 'Name', required: true, placeholder: 'web-release'},
        {name: 'group', label: 'Owning group', type: 'select', options: state.groups}
      ],
      action: function (v) {
        return applyMutation('/api/workflow', v).then(function () {
          state.selected = v.name;
          return loadLists();
        });
      }
    });
  }

  ui.list.addEventListener('click', function (event) {
    var item = event.target.closest('[data-workflow-name]');
    if (item) {
      loadWorkflow(item.dataset.workflowName);
    }
  });
  ui.search.addEventListener('input', renderList);
  // Confirm refreshes visibly even when the data did not change.
  ui.refresh.addEventListener('click', function () {
    Promise.resolve(loadLists()).then(function () {
      var d = new Date();
      showNotice('ok', 'Updated', 'Checked at ' +
        ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) +
        ':' + ('0' + d.getSeconds()).slice(-2) + '.');
    });
  });
  ui.create.addEventListener('click', createWorkflow);
  ui.fit.addEventListener('click', function () { ui.scroll.scrollTo({left: 0, top: 0}); });
  ui.columns.addEventListener('click', function (event) {
    var button = event.target.closest('[data-node-action]');
    var step;
    if (button) {
      step = currentStep(Number(button.dataset.step));
      if (step) {
        nodeAction(button.dataset.nodeAction, step);
      }
    }
  });
  ui.commands.addEventListener('click', function (event) {
    var button = event.target.closest('[data-workflow-action]');
    if (button) {
      workflowAction(button.dataset.workflowAction);
    }
  });
  ui.form.addEventListener('submit', function (event) {
    var submitter = event.submitter;
    event.preventDefault();
    if (!submitter || submitter.value === 'cancel') {
      ui.dialog.close();
      return;
    }
    if (!ui.form.reportValidity() || typeof state.dialogAction !== 'function') {
      return;
    }
    Promise.resolve(state.dialogAction(valuesOfForm())).catch(function (error) {
      ui.formError.textContent = error.message;
      ui.formError.hidden = false;
    });
  });
  window.addEventListener('resize', function () {
    requestAnimationFrame(drawEdges);
  });
  window.addEventListener('pizarra:help', function () {
    if (ui.dialog.open) { setDialogHelp(dialogHelp.route, dialogHelp.fallback); }
  });
  window.addEventListener('pizarra:view', function (event) {
    if (event.detail.name === 'workflows') {
      if (!state.loaded && !state.loading) {
        loadLists();
      } else {
        requestAnimationFrame(drawEdges);
      }
    }
  });
  if (!ui.view.hidden) {
    loadLists();
  }
})();
