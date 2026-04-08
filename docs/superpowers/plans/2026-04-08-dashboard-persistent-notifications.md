# Dashboard Persistent Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make dashboard notifications (recommendations + incidents) persistent with dismiss buttons, auto-dismiss for low-severity items, and auto-fix for safe actions during heartbeat.

**Architecture:** A JSON state file (`~/.clu/dashboard-state.json`) tracks dismissed and auto-fixed items. The dashboard backend filters items against this state. The heartbeat script gains an auto-fix phase that executes safe actions and logs results. Stable IDs (SHA-based) replace sequential numbering for recommendations.

**Tech Stack:** Python stdlib (dashboard.py), Bash (heartbeat.sh), JSON state file

---

### Task 1: State File — Read/Write Infrastructure

**Files:**
- Modify: `dashboard.py:29-40` (add constants)
- Modify: `dashboard.py:44-98` (add state functions after existing parsers)

- [ ] **Step 1: Add state file constant**

In `dashboard.py`, after line 40 (`PROJECTS_DIR = ...`), add:

```python
DASHBOARD_STATE = AGENT_HOME / "dashboard-state.json"
```

- [ ] **Step 2: Add state read/write functions**

After the `parse_simple_yaml` function (after line 98), add:

```python
import hashlib


def _stable_id(description):
    """Generate a stable ID from description text."""
    return hashlib.sha256(description.encode()).hexdigest()[:12]


def read_state():
    """Read dashboard-state.json, return default if missing/corrupt."""
    default = {"dismissed": {}, "autofixed": []}
    if not DASHBOARD_STATE.exists():
        return default
    try:
        return json.loads(DASHBOARD_STATE.read_text())
    except (json.JSONDecodeError, ValueError):
        return default


def write_state(state):
    """Write dashboard state atomically."""
    tmp = DASHBOARD_STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, default=str))
    tmp.rename(DASHBOARD_STATE)


def dismiss_item(item_id):
    """Mark an item as dismissed."""
    state = read_state()
    state["dismissed"][item_id] = {
        "at": datetime.now().isoformat(),
    }
    write_state(state)
    return {"status": "ok", "id": item_id}


def _auto_dismiss_cutoff(severity):
    """Return max age in seconds before auto-dismiss, or None for manual-only."""
    if severity == "low":
        return 7 * 86400
    if severity == "medium":
        return 30 * 86400
    return None  # high/critical: manual only
```

- [ ] **Step 3: Commit**

```bash
git add dashboard.py
git commit -m "feat(dashboard): add state file read/write infrastructure"
```

---

### Task 2: Stable IDs for Recommendations

**Files:**
- Modify: `dashboard.py:287-341` (`extract_recommendations` function)

- [ ] **Step 1: Replace sequential IDs with hash-based stable IDs**

In `extract_recommendations`, change the two places where IDs are assigned.

Replace:
```python
                recs.append({
                    "id": f"sec-{len(recs)}",
```

With:
```python
                recs.append({
                    "id": f"rec-{_stable_id(cleaned)}",
```

Replace:
```python
            recs.append({
                "id": f"stale-{len(recs)}",
```

With:
```python
            recs.append({
                "id": f"rec-{_stable_id(sf.strip())}",
```

- [ ] **Step 2: Commit**

```bash
git add dashboard.py
git commit -m "feat(dashboard): use stable hash-based IDs for recommendations"
```

---

### Task 3: Filter Dismissed Items in API

**Files:**
- Modify: `dashboard.py:287-341` (`extract_recommendations` — add filtering)
- Modify: `dashboard.py:213-228` (`parse_security_incidents` — add filtering)

- [ ] **Step 1: Add filtering to `extract_recommendations`**

At the end of `extract_recommendations`, before `return recs`, add filtering logic. Replace the final `return recs` with:

```python
    # Filter dismissed and auto-dismissed items
    state = read_state()
    now = time.time()
    filtered = []
    for r in recs:
        # Manually dismissed?
        if r["id"] in state["dismissed"]:
            continue
        # Auto-dismiss by age?
        cutoff = _auto_dismiss_cutoff(r["severity"])
        if cutoff and r.get("_created"):
            age = now - r["_created"]
            if age > cutoff:
                continue
        filtered.append(r)
    return filtered
```

- [ ] **Step 2: Add `_created` timestamp to recommendations**

Recommendations are derived from static files, so they don't have a natural creation time. Use the security report date as a proxy. At the top of `extract_recommendations`, after `recs = []`, add:

```python
    report = parse_security_report()
    report_date = report.get("date", "")
    try:
        created_ts = datetime.strptime(report_date, "%Y-%m-%d").timestamp()
    except (ValueError, TypeError):
        created_ts = time.time()
```

Then in each `recs.append(...)` call, add `"_created": created_ts` to the dict for security recs, and `time.time()` for stale-file recs (since those are live-detected).

For the security rec append (first one):
```python
                recs.append({
                    "id": f"rec-{_stable_id(cleaned)}",
                    "category": "security",
                    "description": cleaned,
                    "severity": severity,
                    "action": action,
                    "action_param": param,
                    "_created": created_ts,
                })
```

For the stale-file rec append (second one):
```python
            recs.append({
                "id": f"rec-{_stable_id(sf.strip())}",
                "category": "maintenance",
                "description": sf.strip(),
                "severity": "medium",
                "action": "heartbeat",
                "_created": time.time(),
            })
```

- [ ] **Step 3: Add `show_dismissed` query param support**

We need a way to return all items (including dismissed) for the "show dismissed" toggle. This is handled in the HTTP handler — see Task 5.

- [ ] **Step 4: Add filtering to `parse_security_incidents`**

Add an optional `include_dismissed=False` parameter and filter:

```python
def parse_security_incidents(include_dismissed=False):
    """Parse the persistent security incident log (JSONL)."""
    if not SECURITY_INCIDENTS.exists():
        return []
    incidents = []
    for line in SECURITY_INCIDENTS.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            inc = json.loads(line)
            inc.setdefault("id", f"inc-{_stable_id(inc.get('timestamp', '') + inc.get('detail', ''))}")
            incidents.append(inc)
        except json.JSONDecodeError:
            continue
    incidents.reverse()

    if not include_dismissed:
        state = read_state()
        now = time.time()
        filtered = []
        for inc in incidents:
            if inc["id"] in state["dismissed"]:
                continue
            # Auto-dismiss low-severity incidents by age
            sev = inc.get("severity", "medium")
            cutoff = _auto_dismiss_cutoff(sev)
            if cutoff and inc.get("timestamp"):
                try:
                    inc_ts = datetime.fromisoformat(inc["timestamp"]).timestamp()
                    if now - inc_ts > cutoff:
                        continue
                except (ValueError, TypeError):
                    pass
            filtered.append(inc)
        incidents = filtered

    return incidents
```

- [ ] **Step 5: Commit**

```bash
git add dashboard.py
git commit -m "feat(dashboard): filter dismissed and auto-dismissed items from API"
```

---

### Task 4: Dismiss API Endpoint

**Files:**
- Modify: `dashboard.py:1056-1074` (`do_POST` method)

- [ ] **Step 1: Add dismiss endpoint to `do_POST`**

After the `/api/action` block, add:

```python
        elif path == "/api/dismiss":
            item_id = body.get("id", "")
            if not item_id:
                self._send_json({"error": "missing id"}, 400)
                return
            result = dismiss_item(item_id)
            self._send_json(result)
```

- [ ] **Step 2: Add `show_dismissed` param to GET handlers**

In `do_GET`, update the incidents and recommendations handlers to check for query params:

```python
        elif path == "/api/recommendations":
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            show_all = "show_dismissed" in qs
            self._send_json(extract_recommendations(include_dismissed=show_all))
        elif path == "/api/incidents":
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            show_all = "show_dismissed" in qs
            self._send_json(parse_security_incidents(include_dismissed=show_all))
```

This means `extract_recommendations` also needs the `include_dismissed` parameter. Add it:

```python
def extract_recommendations(include_dismissed=False):
```

And wrap the filtering block at the end in `if not include_dismissed:`.

- [ ] **Step 3: Commit**

```bash
git add dashboard.py
git commit -m "feat(dashboard): add dismiss API endpoint and show_dismissed param"
```

---

### Task 5: UI — Dismiss Buttons and Show-Dismissed Toggle

**Files:**
- Modify: `dashboard.py` — `DASHBOARD_HTML` string (CSS, JS render functions)

- [ ] **Step 1: Add dismiss button CSS**

In the `<style>` block, after the `.sev-low` rule (around line 615), add:

```css
.dismiss-btn {
    background: none; border: none; color: var(--text-dim); cursor: pointer;
    font-size: 16px; padding: 2px 6px; line-height: 1; flex-shrink: 0;
    opacity: 0.5; transition: opacity 0.15s;
}
.dismiss-btn:hover { opacity: 1; color: var(--red); }
.autofixed-badge {
    display: inline-block; background: rgba(63,185,80,0.15); color: var(--green);
    font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 4px;
}
.show-dismissed-toggle {
    display: flex; align-items: center; gap: 6px; padding: 8px 0;
    color: var(--text-dim); font-size: 12px; cursor: pointer;
}
.show-dismissed-toggle input { cursor: pointer; }
.dismissed-item { opacity: 0.4; }
```

- [ ] **Step 2: Add dismiss JS function**

In the `<script>` section, after the `runAction` function, add:

```javascript
async function dismissItem(id, el) {
    await fetch('/api/dismiss', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({id})
    });
    if (el) el.closest('.rec-item, tr')?.remove();
    refreshAll();
}
```

- [ ] **Step 3: Add show-dismissed state variable**

At the top of the `<script>` section, after `let data = {};`, add:

```javascript
let showDismissed = false;
```

- [ ] **Step 4: Update `renderRecommendations` with dismiss buttons**

Replace the `renderRecommendations` function:

```javascript
function renderRecommendations(recs) {
    const list = document.getElementById('rec-list');
    const actTab = document.querySelector('[data-panel="actions"]');
    if (!recs.length) {
        list.innerHTML = '<li class="empty">No pending recommendations.</li>';
        actTab.textContent = 'Actions';
        return;
    }
    const active = recs.filter(r => !r._dismissed);
    actTab.innerHTML = active.length ? `Actions <span class="badge">${active.length}</span>` : 'Actions';
    list.innerHTML = recs.map(r => {
        const dimClass = r._dismissed ? ' dismissed-item' : '';
        return `
        <li class="rec-item${dimClass}" title="${escapeHtml(r.description)}">
            <span class="rec-severity sev-${r.severity}">${r.severity}</span>
            <span class="rec-text">${escapeHtml(r.description)}</span>
            ${r.action ? `<button class="rec-action-btn" data-action="${escapeHtml(r.action)}" data-param="${escapeHtml(r.action_param || '')}" onclick="runRecAction(this)" title="Run: ${escapeHtml(r.action)}">${recButtonLabel(r.action)}</button>` : ''}
            <button class="dismiss-btn" onclick="dismissItem('${escapeHtml(r.id)}', this)" title="Dismiss">&times;</button>
        </li>`;
    }).join('');
}
```

- [ ] **Step 5: Update `renderIncidents` with dismiss buttons**

Replace the incident table row rendering in `renderIncidents`:

```javascript
function renderIncidents(incidents) {
    const el = document.getElementById('incident-list');
    const incTab = document.querySelector('[data-panel="incidents"]');

    if (!incidents || !incidents.length) {
        el.innerHTML = '<p class="empty">No security incidents recorded.</p>';
        incTab.textContent = 'Incidents';
        return;
    }

    const active = incidents.filter(i => !i._dismissed);
    incTab.innerHTML = active.length ? `Incidents <span class="badge">${active.length}</span>` : 'Incidents';

    el.innerHTML = `<table>
        <tr><th>Time</th><th>Severity</th><th>Source</th><th>Detail</th><th></th></tr>
        ${incidents.map(i => {
            const sevCls = i.severity === 'critical' ? 'status-critical' : i.severity === 'high' ? 'status-issues' : 'status-unknown';
            const dimClass = i._dismissed ? ' dismissed-item' : '';
            return `<tr class="${dimClass}">
                <td style="white-space:nowrap">${escapeHtml(i.timestamp || '?')}</td>
                <td><span class="status-badge ${sevCls}">${escapeHtml(i.severity || '?')}</span></td>
                <td>${escapeHtml(i.source || '?')}</td>
                <td>${escapeHtml(i.detail || '')}</td>
                <td><button class="dismiss-btn" onclick="dismissItem('${escapeHtml(i.id)}', this)" title="Dismiss">&times;</button></td>
            </tr>`;
        }).join('')}
    </table>`;
}
```

- [ ] **Step 6: Add show-dismissed toggles to Actions and Incidents panels**

In the HTML, add a toggle inside the Actions panel card (after the `<ul class="rec-list">`):

```html
<label class="show-dismissed-toggle">
    <input type="checkbox" id="toggle-dismissed" onchange="toggleDismissed(this.checked)">
    Show dismissed
</label>
```

Add the same toggle inside the Incidents panel card (after the `<div id="incident-list">`):

```html
<label class="show-dismissed-toggle">
    <input type="checkbox" id="toggle-dismissed-inc" onchange="toggleDismissed(this.checked)">
    Show dismissed
</label>
```

Add the toggle handler in JS:

```javascript
function toggleDismissed(show) {
    showDismissed = show;
    document.getElementById('toggle-dismissed').checked = show;
    document.getElementById('toggle-dismissed-inc').checked = show;
    refreshAll();
}
```

- [ ] **Step 7: Update `refreshAll` to pass `show_dismissed` param**

In the `refreshAll` function, update the recommendations and incidents API calls:

```javascript
const qs = showDismissed ? '?show_dismissed=1' : '';
const [security, heartbeat, projects, recs, incidents] = await Promise.all([
    safe(() => api('security')), safe(() => api('heartbeat')), safe(() => api('projects')),
    safe(() => api('recommendations' + qs)), safe(() => api('incidents' + qs)),
]);
```

- [ ] **Step 8: Commit**

```bash
git add dashboard.py
git commit -m "feat(dashboard): add dismiss buttons and show-dismissed toggles to UI"
```

---

### Task 6: Auto-Fix Infrastructure in Dashboard

**Files:**
- Modify: `dashboard.py` — add `autofix_safe_actions` function after `execute_action`

- [ ] **Step 1: Add auto-fix function**

After `execute_action` (around line 516), add:

```python
SAFE_AUTOFIX_ACTIONS = {"shell-clean", "refresh-hashes", "remove-skill"}


def autofix_safe_actions():
    """Run safe auto-fixable recommendations and log results.

    Called by heartbeat. Only executes actions in SAFE_AUTOFIX_ACTIONS.
    Returns list of auto-fix results.
    """
    recs = extract_recommendations(include_dismissed=True)
    state = read_state()
    results = []

    for r in recs:
        if r["id"] in state["dismissed"]:
            continue
        if r.get("action") not in SAFE_AUTOFIX_ACTIONS:
            continue
        if r["severity"] not in ("high", "critical"):
            continue

        result = execute_action(r["action"], r.get("action_param"))
        entry = {
            "id": r["id"],
            "action": r["action"],
            "description": r["description"],
            "at": datetime.now().isoformat(),
            "result": result.get("status", "error"),
        }
        results.append(entry)

        # Auto-dismiss on success
        if result.get("status") == "ok":
            state["dismissed"][r["id"]] = {
                "at": datetime.now().isoformat(),
            }

    # Append to autofixed log
    state.setdefault("autofixed", [])
    state["autofixed"].extend(results)
    # Keep only last 50 entries
    state["autofixed"] = state["autofixed"][-50:]
    write_state(state)
    return results
```

- [ ] **Step 2: Add autofix API endpoint for heartbeat to call**

In `do_POST`, add:

```python
        elif path == "/api/autofix":
            results = autofix_safe_actions()
            self._send_json({"status": "ok", "fixed": results})
```

- [ ] **Step 3: Add autofix GET endpoint to show recent autofixes**

In `do_GET`, add:

```python
        elif path == "/api/autofixed":
            state = read_state()
            self._send_json(state.get("autofixed", []))
```

- [ ] **Step 4: Commit**

```bash
git add dashboard.py
git commit -m "feat(dashboard): add auto-fix infrastructure for safe actions"
```

---

### Task 7: Heartbeat Auto-Fix Integration

**Files:**
- Modify: `heartbeat.sh` — add auto-fix phase after security audit

- [ ] **Step 1: Find the right insertion point**

The auto-fix call should happen after the security audit writes its report (which populates recommendations). Look for the end of the agent-driven audit section.

Read `heartbeat.sh` around line 540-580 to find the insertion point.

- [ ] **Step 2: Add auto-fix phase to heartbeat**

After the security audit completes (after the agent report is written), add a new section:

```bash
# ── Phase 7: Auto-fix safe recommendations via dashboard ──────
log "── Auto-fix: checking for safe actions..."
if curl -sf http://127.0.0.1:3141/api/recommendations > /dev/null 2>&1; then
    AUTOFIX_RESULT=$(curl -sf -X POST http://127.0.0.1:3141/api/autofix \
        -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo '{"fixed":[]}')
    FIXED_COUNT=$(echo "$AUTOFIX_RESULT" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('fixed',[])))" 2>/dev/null || echo "0")
    if [ "$FIXED_COUNT" -gt 0 ]; then
        log "  ✅ Auto-fixed $FIXED_COUNT safe action(s)"
        echo "$AUTOFIX_RESULT" | python3 -c "
import sys, json
for f in json.load(sys.stdin).get('fixed', []):
    print(f'    → {f[\"action\"]}: {f[\"description\"][:80]} [{f[\"result\"]}]')
" 2>/dev/null | while IFS= read -r line; do log "$line"; done
    else
        log "  ✅ No safe actions to auto-fix"
    fi
else
    log "  ⚠ Dashboard not reachable on :3141, skipping auto-fix"
fi
```

- [ ] **Step 3: Commit**

```bash
git add heartbeat.sh
git commit -m "feat(heartbeat): call dashboard auto-fix for safe actions after audit"
```

---

### Task 8: UI — Show Recent Auto-Fixes

**Files:**
- Modify: `dashboard.py` — `DASHBOARD_HTML` (JS section)

- [ ] **Step 1: Add autofixed rendering to Actions panel**

In the HTML, add a div for autofixed items inside the Actions panel, after the rec-list card:

```html
<div class="card" id="autofixed-card" style="display:none">
    <h3>Recently Auto-Fixed</h3>
    <ul class="rec-list" id="autofixed-list"></ul>
</div>
```

- [ ] **Step 2: Add autofixed rendering function in JS**

```javascript
function renderAutofixed(items) {
    const card = document.getElementById('autofixed-card');
    const list = document.getElementById('autofixed-list');
    if (!items || !items.length) {
        card.style.display = 'none';
        return;
    }
    card.style.display = 'block';
    list.innerHTML = items.slice(0, 10).map(f => `
        <li class="rec-item">
            <span class="autofixed-badge">auto-fixed</span>
            <span class="rec-text">${escapeHtml(f.description || f.action)}</span>
            <span style="color:var(--text-dim); font-size:12px">${escapeHtml(f.at?.slice(0,16) || '')}</span>
        </li>
    `).join('');
}
```

- [ ] **Step 3: Add autofixed to `refreshAll`**

Add to the Promise.all:

```javascript
const [security, heartbeat, projects, recs, incidents, autofixed] = await Promise.all([
    safe(() => api('security')), safe(() => api('heartbeat')), safe(() => api('projects')),
    safe(() => api('recommendations' + qs)), safe(() => api('incidents' + qs)),
    safe(() => api('autofixed')),
]);
```

And add after the incidents render line:

```javascript
if (autofixed) renderAutofixed(autofixed);
```

- [ ] **Step 4: Commit**

```bash
git add dashboard.py
git commit -m "feat(dashboard): show recently auto-fixed items in Actions panel"
```

---

### Task 9: Restart Dashboard Service

- [ ] **Step 1: Restart the systemd service to pick up changes**

```bash
systemctl --user restart clu-dashboard.service
```

- [ ] **Step 2: Verify it's running**

```bash
systemctl --user status clu-dashboard.service
curl -sf http://127.0.0.1:3141/api/recommendations | python3 -m json.tool | head -20
```

- [ ] **Step 3: Test dismiss endpoint**

```bash
# Get a recommendation ID
REC_ID=$(curl -sf http://127.0.0.1:3141/api/recommendations | python3 -c "import sys,json; r=json.load(sys.stdin); print(r[0]['id'] if r else 'none')")
echo "Testing dismiss for: $REC_ID"

# Dismiss it
curl -sf -X POST http://127.0.0.1:3141/api/dismiss \
    -H "Content-Type: application/json" \
    -d "{\"id\": \"$REC_ID\"}" | python3 -m json.tool

# Verify it's gone
curl -sf http://127.0.0.1:3141/api/recommendations | python3 -m json.tool

# Verify it shows with show_dismissed
curl -sf "http://127.0.0.1:3141/api/recommendations?show_dismissed=1" | python3 -m json.tool
```

- [ ] **Step 4: Commit final state**

```bash
git add -A
git commit -m "feat(dashboard): persistent notifications with dismiss, auto-dismiss, and auto-fix"
```
