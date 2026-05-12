/* app.js — M365 User Offboarding Portal */
(function () {
  'use strict';

  /* ── State ────────────────────────────────────────────────────────────── */
  const state = {
    context:      null,
    users:        [],
    userTotal:    0,
    userPage:     1,
    userSearch:   '',
    selected:     new Set(),      // Set of user IDs
    userDetails:  {},             // id → detail object cache
    results:      null,           // last offboarding results array
    steps: {
      CleanupPermissions:    { enabled: true,  label: 'Clean Up Admin Roles & Groups',          config: null },
      BlockSignIn:           { enabled: true,  label: 'Block Sign-In & Revoke Sessions',        config: null },
      ConvertSharedMailbox:  { enabled: true,  label: 'Convert to Shared Mailbox',              config: { delegateUpn: '', hideFromGal: false } },
      SetOutOfOffice:        { enabled: true,  label: 'Set Out of Office',                      config: { internalMessage: '', message: '' } },
      SecureDevice:          { enabled: true,  label: 'Secure Device (Intune)',                 config: { action: 'Wipe' }, conditional: true },
      RemoveLicenses:        { enabled: true,  label: 'Remove All Licences',                    config: null },
      TransferOneDrive:      { enabled: true,  label: 'Transfer OneDrive to Manager',           config: null },
      RemoveTeamsAndDLs:     { enabled: true,  label: 'Remove from Teams & Distribution Lists', config: null },
      RemoveDelegatedAccess: { enabled: true,  label: 'Remove Delegated Mailbox Access',        config: null },
      RemoveSharePoint:      { enabled: true,  label: 'Remove SharePoint Memberships',          config: null },
      DisableMfa:            { enabled: true,  label: 'Disable / Reset MFA Methods',            config: null },
    },
  };

  /* ── API helpers ─────────────────────────────────────────────────────── */
  const api = {
    async get(path) {
      const r = await fetch(path);
      if (!r.ok) {
        const txt = await r.text();
        throw new Error(`[${r.status}] ${txt}`);
      }
      return r.json();
    },
    async post(path, body) {
      const r = await fetch(path, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(body),
      });
      if (!r.ok) {
        const txt = await r.text();
        throw new Error(`[${r.status}] ${txt}`);
      }
      return r.json();
    },
  };

  /* ── Utilities ───────────────────────────────────────────────────────── */
  function esc(v) {
    if (v === null || v === undefined) return '';
    return String(v)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function debounce(fn, ms) {
    let t;
    return function (...args) {
      clearTimeout(t);
      t = setTimeout(() => fn.apply(this, args), ms);
    };
  }

  function setLoading(on) {
    document.getElementById('loading-overlay').classList.toggle('hidden', !on);
  }

  function toast(msg, type = 'info') {
    const c = document.getElementById('toast-container');
    const el = document.createElement('div');
    el.className = `toast toast-${type}`;
    el.textContent = msg;
    c.appendChild(el);
    requestAnimationFrame(() => el.classList.add('show'));
    setTimeout(() => {
      el.classList.remove('show');
      setTimeout(() => el.remove(), 320);
    }, 4500);
  }

  function statusBadgeClass(s) {
    return { Success: 'badge-green', Error: 'badge-red', Skipped: 'badge-gray' }[s] ?? 'badge-blue';
  }

  /* ── Router ──────────────────────────────────────────────────────────── */
  function route() {
    // If not connected, always show the connect screen
    if (!state.context?.connected) {
      document.querySelectorAll('.view').forEach(el => el.classList.remove('active'));
      renderConnectView();
      document.getElementById('view-connect').classList.add('active');
      return;
    }

    const view = location.hash.replace(/^#\//, '') || 'users';
    document.querySelectorAll('.view').forEach(el => el.classList.remove('active'));
    document.querySelectorAll('.nav-link').forEach(el => el.classList.remove('active'));

    const viewEl = document.getElementById(`view-${view}`);
    const navEl  = document.querySelector(`[data-view="${view}"]`);
    if (viewEl) viewEl.classList.add('active');
    if (navEl)  navEl.classList.add('active');

    switch (view) {
      case 'users':    renderUsersView();    break;
      case 'offboard': renderOffboardView(); break;
      case 'audit':    renderAuditView();    break;
    }
  }

  /* ── Context ─────────────────────────────────────────────────────────── */
  function updateTenantInfo(ctx) {
    const { tenantName, connectedAs, hasIntuneLicense } = ctx;
    document.getElementById('tenant-info').innerHTML =
      `<span class="badge badge-green">Connected</span>
       <span class="tenant-name">${esc(tenantName)}</span>
       <span class="connected-as">as ${esc(connectedAs)}</span>
       ${!hasIntuneLicense ? '<span class="badge badge-orange" title="Intune step will be skipped">No Intune</span>' : ''}`;
  }

  async function loadContext() {
    try {
      state.context = await api.get('/api/context');
      if (state.context.connected) updateTenantInfo(state.context);
      return state.context.connected;
    } catch (e) {
      document.getElementById('tenant-info').innerHTML =
        `<span class="badge badge-red">Error</span><span class="connected-as">${esc(e.message)}</span>`;
      return false;
    }
  }

  /* ── Connect view ────────────────────────────────────────────────────── */
  function renderConnectView() {
    const view = document.getElementById('view-connect');
    view.innerHTML = `
      <div class="connect-screen">
        <div class="connect-card">
          <div class="connect-icon">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none"
                 stroke="currentColor" stroke-width="1.5"
                 stroke-linecap="round" stroke-linejoin="round">
              <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>
              <line x1="15" y1="9" x2="9" y2="15"/>
              <line x1="9" y1="9" x2="15" y2="15"/>
            </svg>
          </div>
          <h1 class="connect-title">M365 User Offboarding</h1>
          <p class="connect-subtitle">Sign in with a Global Administrator or User Administrator account to continue.</p>
          <div id="connect-status"></div>
          <button class="btn btn-primary btn-connect" id="btn-connect">
            Connect to Microsoft 365
          </button>
          <p class="connect-hint">A browser window will open for Microsoft authentication.</p>
        </div>
      </div>
    `;

    document.getElementById('btn-connect').addEventListener('click', async () => {
      const btn    = document.getElementById('btn-connect');
      const status = document.getElementById('connect-status');
      btn.disabled = true;
      status.innerHTML = `
        <div class="connect-progress">
          <div class="spinner"></div>
          <span>Complete sign-in in the browser window that opened…</span>
        </div>`;
      try {
        const result = await api.post('/api/connect', {});
        state.context = { ...result, connected: true };
        updateTenantInfo(state.context);
        document.getElementById('view-connect').classList.remove('active');
        document.querySelector('.header-nav').style.display = '';
        document.getElementById('btn-close-server').style.display = '';
        document.getElementById('btn-logout').style.display = '';
        location.hash = '#/users';
        route();
        toast(`Connected to ${esc(result.tenantName)}`, 'success');
      } catch (e) {
        btn.disabled = false;
        status.innerHTML = `<div class="connect-error">${esc(e.message)}</div>`;
      }
    });
  }

  /* ════════════════════════════════════════════════════════════════════════
     USERS VIEW
  ════════════════════════════════════════════════════════════════════════ */
  function renderUsersView() {
    const view = document.getElementById('view-users');
    view.innerHTML = `
      <div class="view-header">
        <h2>Users</h2>
        <div class="view-actions">
          <input type="search" id="user-search" class="search-input"
                 placeholder="Search by name or email…" value="${esc(state.userSearch)}" />
          <button id="btn-offboard" class="btn btn-primary" disabled>
            Offboard Selected (<span id="sel-count">${state.selected.size}</span>)
          </button>
        </div>
      </div>
      <div id="user-table-wrap"><div class="spinner centered"></div></div>
      <div id="user-detail-panel" class="detail-panel hidden"></div>
    `;

    document.getElementById('user-search').addEventListener('input',
      debounce(async e => {
        state.userSearch = e.target.value;
        state.userPage   = 1;
        await renderUserTable();
      }, 350)
    );

    document.getElementById('btn-offboard').addEventListener('click', () => {
      if (state.selected.size > 0) location.hash = '#/offboard';
    });

    renderUserTable();
  }

  async function renderUserTable() {
    const wrap = document.getElementById('user-table-wrap');
    if (!wrap) return;
    wrap.innerHTML = '<div class="spinner centered"></div>';

    try {
      const qs   = new URLSearchParams({ search: state.userSearch, page: state.userPage });
      const data = await api.get('/api/users?' + qs.toString());
      state.users     = data.users   ?? [];
      state.userTotal = data.total   ?? 0;
      const hasNext   = data.hasNext ?? (state.users.length === (data.pageSize ?? 25));

      if (state.users.length === 0) {
        wrap.innerHTML = '<p class="empty-state">No users found.</p>';
        return;
      }

      const pageSize   = data.pageSize ?? 25;
      // Graph doesn't support $skip so total may be 0 for cursor-based pages.
      // Use hasNext flag instead of total for the Next button.
      const totalLabel = state.userTotal > 0 ? ` of ~${Math.ceil(state.userTotal / pageSize)}` : '';

      wrap.innerHTML = `
        <table class="data-table" id="user-table">
          <thead>
            <tr>
              <th><input type="checkbox" id="select-all" /></th>
              <th>Display Name</th>
              <th>UPN / Email</th>
              <th>Department</th>
              <th>Job Title</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            ${state.users.map(u => `
              <tr class="user-row${state.selected.has(u.id) ? ' selected' : ''}" data-id="${esc(u.id)}">
                <td><input type="checkbox" class="user-check" data-id="${esc(u.id)}"
                    ${state.selected.has(u.id) ? 'checked' : ''} /></td>
                <td class="user-name-cell">
                  <div class="avatar">${esc((u.displayName || '?')[0].toUpperCase())}</div>
                  ${esc(u.displayName || '(no name)')}
                </td>
                <td class="upn-cell">${esc(u.userPrincipalName || '')}</td>
                <td>${esc(u.department || '—')}</td>
                <td>${esc(u.jobTitle   || '—')}</td>
                <td>
                  <span class="badge ${u.accountEnabled ? 'badge-green' : 'badge-red'}">
                    ${u.accountEnabled ? 'Active' : 'Blocked'}
                  </span>
                </td>
              </tr>
            `).join('')}
          </tbody>
        </table>
        <div class="pagination">
          <button class="btn btn-sm" id="page-prev" ${state.userPage <= 1 ? 'disabled' : ''}>← Prev</button>
          <span>Page ${state.userPage}${totalLabel}</span>
          <button class="btn btn-sm" id="page-next" ${!hasNext ? 'disabled' : ''}>Next →</button>
        </div>
      `;

      // Select-all checkbox
      document.getElementById('select-all').addEventListener('change', e => {
        state.users.forEach(u => e.target.checked ? state.selected.add(u.id) : state.selected.delete(u.id));
        syncSelectionUI();
        renderUserTable();
      });

      // Per-row checkboxes
      wrap.querySelectorAll('.user-check').forEach(cb => {
        cb.addEventListener('change', e => {
          const id = e.target.dataset.id;
          e.target.checked ? state.selected.add(id) : state.selected.delete(id);
          e.target.closest('tr').classList.toggle('selected', e.target.checked);
          syncSelectionUI();
        });
      });

      // Click name to open detail panel
      wrap.querySelectorAll('.user-name-cell').forEach(cell => {
        cell.addEventListener('click', () => {
          const id = cell.closest('tr').dataset.id;
          openUserDetail(id);
        });
      });

      // Pagination
      document.getElementById('page-prev')?.addEventListener('click', async () => {
        if (state.userPage > 1) { state.userPage--; await renderUserTable(); }
      });
      document.getElementById('page-next')?.addEventListener('click', async () => {
        if (hasNext) { state.userPage++; await renderUserTable(); }
      });

    } catch (e) {
      wrap.innerHTML = `<p class="error-text">Failed to load users: ${esc(e.message)}</p>`;
    }
  }

  function syncSelectionUI() {
    const btn  = document.getElementById('btn-offboard');
    const span = document.getElementById('sel-count');
    if (btn)  btn.disabled     = state.selected.size === 0;
    if (span) span.textContent = state.selected.size;
  }

  async function openUserDetail(userId) {
    const panel = document.getElementById('user-detail-panel');
    if (!panel) return;
    panel.classList.remove('hidden');
    panel.innerHTML = '<div class="spinner centered"></div>';

    try {
      if (!state.userDetails[userId]) {
        state.userDetails[userId] = await api.get('/api/users/' + userId);
      }
      const d = state.userDetails[userId];
      const isSelected = state.selected.has(userId);

      panel.innerHTML = `
        <div class="detail-header">
          <div class="avatar large">${esc((d.displayName || '?')[0].toUpperCase())}</div>
          <div>
            <h3>${esc(d.displayName || '')}</h3>
            <div class="detail-upn">${esc(d.userPrincipalName || '')}</div>
            <div class="detail-meta">
              ${esc(d.jobTitle || '')}${d.department ? ' · ' + esc(d.department) : ''}
              ${d.manager ? ' · Manager: ' + esc(d.manager.displayName) : ''}
            </div>
          </div>
          <button class="btn btn-ghost detail-close" id="close-detail">✕</button>
        </div>
        <div class="detail-grid">
          <div class="detail-section">
            <h4>Licences (${(d.licenses || []).length})</h4>
            ${(d.licenses || []).length
              ? d.licenses.map(l => `<span class="badge badge-blue" style="margin:2px">${esc(l)}</span>`).join(' ')
              : '<span class="dim">None</span>'}
          </div>
          <div class="detail-section">
            <h4>Admin Roles (${(d.roles || []).length})</h4>
            ${(d.roles || []).length
              ? d.roles.map(r => `<span class="badge badge-orange" style="margin:2px">${esc(r)}</span>`).join(' ')
              : '<span class="dim">None</span>'}
          </div>
          <div class="detail-section">
            <h4>Groups (${(d.groups || []).length})</h4>
            <div class="scrollable-list">
              ${(d.groups || []).slice(0, 15).map(g => `<div class="list-item">${esc(g)}</div>`).join('')
                || '<span class="dim">None</span>'}
              ${(d.groups || []).length > 15
                ? `<div class="dim">… and ${d.groups.length - 15} more</div>` : ''}
            </div>
          </div>
          <div class="detail-section">
            <h4>Managed Devices (${(d.devices || []).length})</h4>
            ${(d.devices || []).length
              ? d.devices.map(dv => `
                  <div class="list-item">
                    <span class="badge badge-gray">${esc(dv.os || '?')}</span> ${esc(dv.name || '')}
                    <span class="dim">(${esc(dv.ownerType || '')})</span>
                  </div>`).join('')
              : '<span class="dim">None</span>'}
          </div>
        </div>
        <div class="detail-footer">
          <button class="btn ${isSelected ? 'btn-outline' : 'btn-primary'} btn-sm"
                  id="toggle-select-user" data-id="${esc(userId)}">
            ${isSelected ? '✓ Selected — Click to Deselect' : 'Add to Offboarding Selection'}
          </button>
          <span class="badge ${d.accountEnabled ? 'badge-green' : 'badge-red'}">
            ${d.accountEnabled ? 'Account Active' : 'Account Blocked'}
          </span>
        </div>
      `;

      document.getElementById('close-detail').addEventListener('click', () => panel.classList.add('hidden'));
      document.getElementById('toggle-select-user').addEventListener('click', e => {
        const id = e.target.dataset.id;
        if (state.selected.has(id)) {
          state.selected.delete(id);
          e.target.textContent = 'Add to Offboarding Selection';
          e.target.className   = 'btn btn-primary btn-sm';
        } else {
          state.selected.add(id);
          e.target.textContent = '✓ Selected — Click to Deselect';
          e.target.className   = 'btn btn-outline btn-sm';
        }
        syncSelectionUI();
      });

    } catch (e) {
      panel.innerHTML = `<p class="error-text">Failed to load user details: ${esc(e.message)}</p>`;
    }
  }

  /* ════════════════════════════════════════════════════════════════════════
     OFFBOARD VIEW
  ════════════════════════════════════════════════════════════════════════ */
  function renderOffboardView() {
    const view = document.getElementById('view-offboard');
    const selIds = [...state.selected];

    if (selIds.length === 0) {
      view.innerHTML = `
        <div class="empty-state-centered">
          <div class="empty-icon">👤</div>
          <h3>No users selected</h3>
          <p>Go to <a href="#/users">Users</a>, select one or more accounts, then return here.</p>
        </div>`;
      return;
    }

    const hasResults = state.results !== null;

    view.innerHTML = `
      <div class="view-header">
        <h2>Offboard ${selIds.length} User${selIds.length !== 1 ? 's' : ''}</h2>
        <div class="view-actions">
          ${hasResults
            ? `<button class="btn btn-outline" id="btn-reset-offboard">← Start New</button>`
            : `<button class="btn btn-danger"   id="btn-execute">Execute Offboarding</button>`
          }
        </div>
      </div>
      <div class="offboard-grid">
        <div class="steps-column${hasResults ? ' hidden' : ''}">
          <p class="col-heading">Offboarding Steps</p>
          ${renderStepCards()}
        </div>
        <div class="results-column">
          ${hasResults ? renderResultsHTML() : renderSelectedUsersHTML(selIds)}
        </div>
      </div>
    `;

    if (!hasResults) {
      wireStepCards();
      document.getElementById('btn-execute')?.addEventListener('click', executeOffboarding);

      // Remove-user buttons inside selected list
      view.querySelectorAll('.remove-selected-user').forEach(btn => {
        btn.addEventListener('click', e => {
          const id = e.target.dataset.id;
          state.selected.delete(id);
          renderOffboardView();
        });
      });
    } else {
      document.getElementById('btn-reset-offboard')?.addEventListener('click', () => {
        state.results = null;
        state.selected.clear();
        location.hash = '#/users';
      });
      document.getElementById('btn-export-results')?.addEventListener('click', exportAudit);
    }
  }

  function renderStepCards() {
    return Object.entries(state.steps).map(([key, step]) => `
      <div class="step-card ${step.enabled ? 'enabled' : 'disabled'}" data-key="${esc(key)}">
        <div class="step-card-header">
          <label class="toggle-label" title="Enable/disable this step">
            <input type="checkbox" class="step-toggle" data-key="${esc(key)}" ${step.enabled ? 'checked' : ''} />
            <span class="toggle-slider"></span>
          </label>
          <span class="step-name">${esc(step.label)}</span>
          ${step.conditional
            ? '<span class="badge badge-orange" title="Only runs if tenant has an Intune licence">Conditional</span>'
            : ''}
        </div>
        ${renderStepConfigHTML(key, step)}
      </div>
    `).join('');
  }

  function renderStepConfigHTML(key, step) {
    if (!step.config) return '';
    if (key === 'ConvertSharedMailbox') {
      return `<div class="step-config">
        <label>Delegate access to (UPN — optional)
          <input type="text" class="config-input" data-key="${key}" data-field="delegateUpn"
                 value="${esc(step.config.delegateUpn || '')}"
                 placeholder="manager@company.com" />
        </label>
        <label class="toggle-row">
          <input type="checkbox" class="config-input" data-key="${key}" data-field="hideFromGal"
                 ${step.config.hideFromGal ? 'checked' : ''} />
          Hide mailbox from Global Address List (GAL)
        </label>
      </div>`;
    }
    if (key === 'SetOutOfOffice') {
      return `<div class="step-config">
        <label>Internal message
          <textarea class="config-input" data-key="${key}" data-field="internalMessage"
                    rows="2" placeholder="John has left the company. Please contact…">${esc(step.config.internalMessage || '')}</textarea>
        </label>
        <label>External message (leave blank to mirror internal)
          <textarea class="config-input" data-key="${key}" data-field="message"
                    rows="2" placeholder="Same message or different for external senders…">${esc(step.config.message || '')}</textarea>
        </label>
      </div>`;
    }
    if (key === 'SecureDevice') {
      return `<div class="step-config">
        <label>Device action
          <select class="config-input" data-key="${key}" data-field="action">
            <option value="Wipe"  ${step.config.action === 'Wipe'  ? 'selected' : ''}>Retire / Wipe — remove company data (BYOD)</option>
            <option value="Reset" ${step.config.action === 'Reset' ? 'selected' : ''}>Factory Reset — full wipe (company-owned device)</option>
          </select>
        </label>
      </div>`;
    }
    return '';
  }

  function wireStepCards() {
    document.querySelectorAll('.step-toggle').forEach(cb => {
      cb.addEventListener('change', e => {
        const key = e.target.dataset.key;
        state.steps[key].enabled = e.target.checked;
        const card = e.target.closest('.step-card');
        card.classList.toggle('enabled',  e.target.checked);
        card.classList.toggle('disabled', !e.target.checked);
      });
    });

    document.querySelectorAll('.config-input').forEach(inp => {
      const update = e => {
        const { key, field } = e.target.dataset;
        if (state.steps[key]?.config) {
          state.steps[key].config[field] =
            e.target.type === 'checkbox' ? e.target.checked : e.target.value;
        }
      };
      inp.addEventListener('input', update);
      inp.addEventListener('change', update);
    });
  }

  function renderSelectedUsersHTML(selIds) {
    const users = selIds.map(id => {
      const cached = state.userDetails[id] || state.users.find(u => u.id === id);
      return cached || { id, displayName: id, userPrincipalName: '' };
    });

    return `
      <p class="col-heading">Selected Users (${users.length})</p>
      <div class="selected-users-list">
        ${users.map(u => `
          <div class="selected-user-item">
            <div class="avatar">${esc((u.displayName || '?')[0].toUpperCase())}</div>
            <div style="flex:1;min-width:0">
              <div class="user-name">${esc(u.displayName || u.userPrincipalName || u.id)}</div>
              <div class="user-upn dim">${esc(u.userPrincipalName || '')}</div>
            </div>
            <button class="btn btn-xs btn-ghost remove-selected-user" data-id="${esc(u.id)}">✕</button>
          </div>
        `).join('')}
      </div>
      <p class="dim" style="margin-top:12px">
        Review steps on the left, then click <strong>Execute Offboarding</strong>.
        All enabled steps will run in order for each selected user.
      </p>
    `;
  }

  function renderResultsHTML() {
    const results = state.results;
    return `
      <p class="col-heading">Results</p>
      <div class="results-wrap">
        ${results.map(ur => `
          <div class="user-result-block">
            <h4>${esc(ur.displayName || ur.userUPN)}</h4>
            <table class="result-table">
              <thead><tr><th>Step</th><th>Status</th><th>Details</th></tr></thead>
              <tbody>
                ${(ur.steps || []).map(s => `
                  <tr class="result-${(s.status || s.Status || '').toLowerCase()}">
                    <td>${esc(s.stepLabel || s.StepLabel || s.step || s.Step)}</td>
                    <td><span class="badge ${statusBadgeClass(s.status || s.Status)}">${esc(s.status || s.Status)}</span></td>
                    <td class="result-message">${esc(s.message || s.Message || '')}</td>
                  </tr>
                `).join('')}
              </tbody>
            </table>
          </div>
        `).join('')}
      </div>
      <div class="results-actions">
        <button class="btn btn-outline" onclick="location.hash='#/audit'">View Audit Log</button>
        <button class="btn btn-primary" id="btn-export-results">Export Audit Log</button>
      </div>
    `;
  }

  async function executeOffboarding() {
    const userIds = [...state.selected];
    if (userIds.length === 0) return;

    // Build step config payload
    const stepsPayload = {};
    Object.entries(state.steps).forEach(([key, step]) => {
      stepsPayload[key] = { enabled: step.enabled, ...(step.config || {}) };
    });

    setLoading(true);
    toast('Offboarding in progress… this may take a few minutes.', 'info');

    try {
      const response = await api.post('/api/offboard', { userIds, steps: stepsPayload });
      state.results = response.results ?? [];

      const success = state.results.reduce((n, ur) =>
        n + (ur.steps || []).filter(s => (s.status || s.Status) === 'Success').length, 0);
      const errors = state.results.reduce((n, ur) =>
        n + (ur.steps || []).filter(s => (s.status || s.Status) === 'Error').length, 0);

      renderOffboardView();
      toast(
        `Offboarding complete — ${success} step(s) succeeded, ${errors} failed.`,
        errors > 0 ? 'warn' : 'success'
      );
    } catch (e) {
      toast('Offboarding failed: ' + e.message, 'error');
    } finally {
      setLoading(false);
    }
  }

  async function exportAudit() {
    try {
      const res = await api.post('/api/export-audit', {});
      toast('Audit log exported: ' + (res.filename || 'see Output/AuditLogs/'), 'success');
    } catch (e) {
      toast('Export failed: ' + e.message, 'error');
    }
  }

  /* ════════════════════════════════════════════════════════════════════════
     AUDIT VIEW
  ════════════════════════════════════════════════════════════════════════ */
  async function renderAuditView() {
    const view = document.getElementById('view-audit');
    view.innerHTML = `
      <div class="view-header">
        <h2>Audit Log</h2>
        <div class="view-actions">
          <button class="btn btn-outline" id="btn-refresh-audit">Refresh</button>
          <button class="btn btn-primary" id="btn-export-audit">Export (HTML + CSV)</button>
        </div>
      </div>
      <div id="audit-wrap"><div class="spinner centered"></div></div>
    `;

    document.getElementById('btn-refresh-audit').addEventListener('click', () => renderAuditView());
    document.getElementById('btn-export-audit').addEventListener('click', exportAudit);

    await loadAuditTable();
  }

  async function loadAuditTable() {
    const wrap = document.getElementById('audit-wrap');
    if (!wrap) return;
    try {
      const data    = await api.get('/api/audit');
      const entries = data.entries ?? [];

      if (entries.length === 0) {
        wrap.innerHTML = '<p class="empty-state">No audit entries yet — run an offboarding first.</p>';
        return;
      }

      const success = entries.filter(e => (e.status || e.Status) === 'Success').length;
      const errors  = entries.filter(e => (e.status || e.Status) === 'Error').length;
      const skipped = entries.filter(e => (e.status || e.Status) === 'Skipped').length;

      wrap.innerHTML = `
        <table class="data-table audit-table">
          <thead>
            <tr>
              <th>Timestamp</th>
              <th>User</th>
              <th>Step</th>
              <th>Status</th>
              <th>Details</th>
            </tr>
          </thead>
          <tbody>
            ${entries.map(e => {
              const status = e.status || e.Status || '';
              return `
                <tr class="result-${status.toLowerCase()}">
                  <td class="timestamp">${esc(e.timestamp || e.Timestamp || '')}</td>
                  <td>${esc(e.userUPN || e.UserUPN || e.userId || '')}</td>
                  <td>${esc(e.stepLabel || e.StepLabel || e.step || e.Step || '')}</td>
                  <td><span class="badge ${statusBadgeClass(status)}">${esc(status)}</span></td>
                  <td class="result-message">${esc(e.message || e.Message || '')}</td>
                </tr>`;
            }).join('')}
          </tbody>
        </table>
        <div class="audit-summary">
          ${entries.length} total &nbsp;·&nbsp;
          <span style="color:var(--success)">${success} succeeded</span> &nbsp;·&nbsp;
          <span style="color:var(--danger)">${errors} failed</span> &nbsp;·&nbsp;
          <span style="color:var(--text-dim)">${skipped} skipped</span>
        </div>
      `;
    } catch (e) {
      if (wrap) wrap.innerHTML = `<p class="error-text">Failed to load audit log: ${esc(e.message)}</p>`;
    }
  }

  /* ════════════════════════════════════════════════════════════════════════
     INIT
  ════════════════════════════════════════════════════════════════════════ */
  document.addEventListener('DOMContentLoaded', async () => {
    window.addEventListener('hashchange', route);

    // Close server button
    document.getElementById('btn-close-server')?.addEventListener('click', async () => {
      if (!confirm('Stop the offboarding portal server?')) return;
      try {
        await api.post('/api/close', {});
        document.body.innerHTML = `
          <div style="display:flex;align-items:center;justify-content:center;height:100vh;flex-direction:column;gap:16px;color:#94a3b8;font-family:sans-serif">
            <div style="font-size:48px">✓</div>
            <h2 style="color:#e2e8f0">Server stopped</h2>
            <p>You can close this browser tab.</p>
          </div>`;
      } catch { /* server closed — expected */ }
    });

    const connected = await loadContext();
    if (!connected) {
      // Hide nav until authenticated; keep Close visible
      document.querySelector('.header-nav').style.display = 'none';
      document.getElementById('tenant-info').innerHTML =
        '<span class="badge badge-gray">Not connected</span>';
      renderConnectView();
      document.getElementById('view-connect').classList.add('active');
    } else {
      document.getElementById('btn-logout').style.display = '';
      route();
    }

    // Logout button
    document.getElementById('btn-logout')?.addEventListener('click', async () => {
      if (!confirm('Disconnect from Microsoft 365 and return to the login screen?')) return;
      try {
        await api.post('/api/disconnect', {});
      } catch (e) {
        toast(`Disconnect error: ${e.message}`, 'warn');
      }
      state.context = null;
      state.users   = [];
      state.selected.clear();
      state.results = null;
      document.getElementById('btn-logout').style.display = 'none';
      document.querySelector('.header-nav').style.display = 'none';
      document.getElementById('tenant-info').innerHTML =
        '<span class="badge badge-gray">Not connected</span>';
      document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
      renderConnectView();
      document.getElementById('view-connect').classList.add('active');
    });
  });
})();
