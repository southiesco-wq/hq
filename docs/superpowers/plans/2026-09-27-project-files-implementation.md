# Shared Project Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every project in Southie's HQ a shared Files section (proposals, plans, reports, brand books, logos, and saved links) that the whole team can see, upload to, and remove from inside the app, backed by Google Drive on southies.co.

**Architecture:** Actual bytes live in Google Drive (one root folder, one subfolder per project). Firestore gets a new `files` collection holding just the metadata (name, project, tag, who added it, Drive file id or external URL), read live via `onSnapshot` exactly like `tasks`. Uploads go straight from the browser to Drive using a resumable-upload session (so a 100MB+ brand book never passes through the Apps Script worker), with the worker only handling the parts that need southies.co's own Drive identity: creating the project's Drive folder, issuing the upload session, making an uploaded file link-viewable, and trashing a file on removal. Since introducing a public `doPost` endpoint on the worker is new attack surface, the worker authenticates each call through a small Firestore "relay" doc that Firestore's own security rules (backed by real Firebase Auth tokens) force to carry the caller's true, verified email — no JWT parsing needed inside Apps Script.

**Tech Stack:** Same as the rest of HQ — a single `index.html` (Firebase JS SDK v10.12.2, compat build, vanilla JS, no framework/bundler), Firestore, Google Apps Script (`apps-script/Code.gs` + `appsscript.json`) as the trusted backend, Firestore Security Rules (`firestore.rules`), Google Drive (DriveApp + one raw resumable-upload REST call).

**Spec:** `docs/superpowers/specs/2026-09-27-project-files-design.md` — this plan implements every requirement in it. Where this plan's mechanics differ slightly from the spec's wording (for example, exactly when a Drive file is "created" during a resumable upload), the behavior described here is what actually ships; the spec's intent (direct-to-Drive upload, uploader-or-Richard removal, permanent storage, All-files page) is unchanged.

## Global Constraints

- No test framework exists in this repo (no pytest/jest/etc.), and the app is a single inline `<script>` in `index.html` with no build step. Every task's verification instead uses the two methods already established in this codebase: (a) a Node syntax check — `new Function(scriptBlockContent)` for `index.html`'s script block, `node --check` for `Code.gs` (copied to a `.js` file first, since Node doesn't recognize `.gs`) — and (b) a manual functional check against the live app using the Claude-in-Chrome browser tool, at a phone-width viewport, plus reading the Apps Script execution log. Do not introduce a test runner.
- End every git commit message with the exact attribution footer given in the session's active system reminder at commit time (a `Co-Authored-By:` line and a `Claude-Session:` link) — copy it verbatim, don't reuse an old one from earlier in this file.
- Editing `firestore.rules` in the repo has **no effect on the live app** — the real, enforced rules live in the Firebase Console (project `southies-hq` → Firestore Database → Rules) and must be pasted there and published.
- Editing `apps-script/Code.gs` or `apps-script/appsscript.json` in the repo has **no effect on the live worker** — push changes into the live "Southie's HQ worker" Apps Script project (script ID `1QaheGo7ig20vlqb8JlYmsm5-WHj33k4Rf3K57QEM2r27UANw5WhBBJSB`) via the Monaco editor's `model.setValue()`, matching the technique used for the push-notification rollout: whole-file replace, then verify by line count and a couple of spot-checked line lengths (never dump raw file content through `javascript_tool`, which false-positives on some string patterns — use `.length`/line-count checks only).
- Adding the `https://www.googleapis.com/auth/drive.file` OAuth scope requires re-authorization. After redeploying, run `setup()` in the Apps Script editor and confirm the execution log is clean (same pattern as the earlier `firebase.messaging` scope rollout).
- Match the existing code's grouping style: new sections in `index.html` and `Code.gs` get their own `/* ---------- section ---------- */` comment header, next to the related existing section.
- New user-facing copy matches the app's existing plain, friendly voice (see `writeError()` in `index.html` for the tone to match).
- This is an internal 6-person tool, not a public product — the security bar in this plan (Firestore rules enforce who can delete a record; the worker's `doPost` only checks "is this a real, current team member," not fine-grained per-action ownership) matches the app's existing trust level (e.g. `createdBy` on a task is already self-reported and not cryptographically checked). Don't over-build verification beyond that bar.

## Review Focus

- A team member who did not upload a file, and who isn't Richard, must not be able to remove it — even by calling `state.db.doc('files/'+id).delete()` directly from the browser console, bypassing the UI's Remove button entirely. This must be rejected by the Firestore rule itself, not just by hiding the button.
- A dropped connection partway through an upload must leave the row showing "Upload failed" with a working Retry, and must never leave an orphan `files` Firestore record pointing at a Drive file that doesn't exist (or vice versa — a Drive file with no Firestore record).
- Deleting a project must leave its files exactly as they were — still visible on the All-files page, just labeled "Removed project" instead of the real project name.
- The worker's new `doPost` endpoint is reachable by anyone on the internet with the URL, not only signed-in team members. A call with a missing, mismatched, stale (>30s old), or already-used nonce must be rejected, not silently processed.
- Saving a link (Canva, Figma, Google Docs) must always open in a new tab, never inside the in-app iframe viewer — those sites refuse to be embedded and would show a broken/blank frame.

---

### Task 1: Firestore rules — `files` and `relay` collections

**Files:**
- Modify: `firestore.rules`

**Interfaces:**
- Produces: the `files/{fileId}` collection (fields: `name`, `project`, `tag`, `kind`, `driveFileId`, `url`, `mimeType`, `size`, `addedBy`, `addedByEmail`, `addedAt`) readable/creatable by any team member, deletable only by its own `addedByEmail` or an owner. The `relay/{uid}` collection, used by later tasks as a one-shot, rules-verified identity handoff to the Apps Script worker.

- [ ] **Step 1: Add the two new `match` blocks**

Edit `firestore.rules` — insert these two blocks right after the existing `match /users/{uid} { ... }` block, before the two closing `}`:

```
    match /files/{fileId} {
      allow read, create: if isTeam();
      allow delete: if isTeam() &&
        (myEmail() == resource.data.addedByEmail || isOwner());
      allow update: if false;
    }
    match /relay/{uid} {
      allow read: if false;
      allow write: if request.auth.uid == uid && isTeam() &&
        request.resource.data.email == myEmail();
    }
```

The full file should now read:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    function signedIn() { return request.auth != null && request.auth.token.email_verified == true; }
    function myEmail() { return request.auth.token.email.lower(); }
    function isOwner() { return signedIn() && myEmail() in ['richatdjames0@gmail.com', 'southies.co@gmail.com']; }
    function isTeam() {
      return signedIn() && (isOwner() ||
        myEmail() in get(/databases/$(database)/documents/config/team).data.emails);
    }

    match /config/{doc} { allow read, write: if isTeam(); }
    match /tasks/{taskId} {
      allow read, write: if isTeam();
      match /comments/{commentId} { allow read, write: if isTeam(); }
    }
    match /presence/{memberKey} { allow read, write: if isTeam(); }
    match /events/{eventId} { allow read, create: if isTeam(); }
    match /pending/{email} { allow read, delete: if signedIn() && myEmail() == email; }
    match /users/{uid} {
      allow read, write: if isTeam() && request.auth.uid == uid;
      match /tasks/{taskId} { allow read, write: if isTeam() && request.auth.uid == uid; }
    }
    match /files/{fileId} {
      allow read, create: if isTeam();
      allow delete: if isTeam() &&
        (myEmail() == resource.data.addedByEmail || isOwner());
      allow update: if false;
    }
    match /relay/{uid} {
      allow read: if false;
      allow write: if request.auth.uid == uid && isTeam() &&
        request.resource.data.email == myEmail();
    }
  }
}
```

- [ ] **Step 2: Commit the local copy**

```bash
cd /home/claude/hq
git add firestore.rules
git commit -m "$(cat <<'EOF'
Add Firestore rules for shared project files and worker relay

EOF
)

<attribution footer active at commit time>"
```

- [ ] **Step 3: Publish the rules to the live project**

Using the Claude-in-Chrome browser tool: navigate to `https://console.firebase.google.com/project/southies-hq/firestore/rules` (use the `/u/1/` account slot if `/u/0/` reports no access, same as the earlier VAPID-key session). Select all the existing rules text, replace it with the full file content from Step 1, and click **Publish**.

- [ ] **Step 4: Verify**

Confirm the console shows "Rules published successfully" (or equivalent) with no red syntax errors. Reload the rules page once and confirm the pasted text matches the file exactly (spot-check the two new `match` blocks are present).

---

### Task 2: Apps Script backend — Drive scope, upload/finalize/trash, orphan sweep

**Files:**
- Modify: `apps-script/appsscript.json`
- Modify: `apps-script/Code.gs`

**Interfaces:**
- Consumes: `getDoc(path)`, `patchDoc(path, data)`, `deleteDoc(path)`, `listDocs(coll)` (existing Firestore REST helpers), `PROJECT_ID`, `APP_URL` (existing constants).
- Produces: a `doPost(e)` web-app entry point dispatching three relay-authenticated actions — `getUploadUrl` → `{uploadUrl}`, `finalizeUpload` → `{url}`, `trashDriveFile` → `{ok:true}` — plus a daily orphan sweep folded into the existing `runCheck()`.

- [ ] **Step 1: Add the Drive scope**

Edit `apps-script/appsscript.json`, adding one entry to `oauthScopes`:

```json
{
  "timeZone": "Asia/Kolkata",
  "runtimeVersion": "V8",
  "exceptionLogging": "STACKDRIVER",
  "oauthScopes": [
    "https://www.googleapis.com/auth/datastore",
    "https://www.googleapis.com/auth/script.external_request",
    "https://www.googleapis.com/auth/script.send_mail",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/script.scriptapp",
    "https://www.googleapis.com/auth/firebase.messaging",
    "https://www.googleapis.com/auth/drive.file"
  ]
}
```

- [ ] **Step 2: Add the `doPost` entry point and relay verification**

In `apps-script/Code.gs`, add this new section right after the `/* ---------- push (FCM) ---------- */` section (after `removePushTokens`, before `/* ---------- calendar ---------- */`):

```js
/* ---------- files (Drive + web endpoint) ---------- */
const FILES_FOLDER_NAME = "Southie's HQ Files";
const RELAY_MAX_AGE_MS = 30000;

function doPost(e) {
  try {
    const body = JSON.parse((e.postData && e.postData.contents) || '{}');
    const uid = body.uid;
    if (!uid) return jsonOut({error: 'missing_uid'});
    const relay = getDoc('relay/' + uid);
    if (!relay || relay.nonce !== body.nonce) return jsonOut({error: 'bad_nonce'});
    if (Date.now() - (relay.ts || 0) > RELAY_MAX_AGE_MS) return jsonOut({error: 'expired'});
    const team = getDoc('config/team');
    const email = String(relay.email || '').toLowerCase();
    if (!team || (team.emails || []).indexOf(email) < 0) return jsonOut({error: 'not_team'});
    deleteDoc('relay/' + uid); // single-use, so a captured request can't be replayed
    const action = relay.action;
    if (action === 'getUploadUrl') return jsonOut(handleGetUploadUrl(relay, team));
    if (action === 'finalizeUpload') return jsonOut(handleFinalizeUpload(relay));
    if (action === 'trashDriveFile') return jsonOut(handleTrashDriveFile(relay));
    return jsonOut({error: 'unknown_action'});
  } catch (err) {
    return jsonOut({error: 'server_error', message: String(err)});
  }
}
function jsonOut(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
function ensureRootFolder(team) {
  if (team.filesRootFolderId) {
    try { return DriveApp.getFolderById(team.filesRootFolderId); } catch (e) { /* fall through and recreate */ }
  }
  const f = DriveApp.createFolder(FILES_FOLDER_NAME);
  patchDoc('config/team', {filesRootFolderId: f.getId()});
  return f;
}
function ensureProjectFolder(team, projectKey) {
  const root = ensureRootFolder(team);
  const projects = team.projects || [];
  let idx = -1;
  for (let i = 0; i < projects.length; i++) if (projects[i].key === projectKey) { idx = i; break; }
  if (idx < 0) throw new Error('unknown_project');
  if (projects[idx].driveFolderId) {
    try { return DriveApp.getFolderById(projects[idx].driveFolderId); } catch (e) { /* fall through and recreate */ }
  }
  const folder = root.createFolder(projects[idx].name || projectKey);
  const projects2 = projects.map((p, i) => i === idx ? Object.assign({}, p, {driveFolderId: folder.getId()}) : p);
  patchDoc('config/team', {projects: projects2});
  return folder;
}
function handleGetUploadUrl(relay, team) {
  const folder = ensureProjectFolder(team, relay.project);
  const r = UrlFetchApp.fetch('https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id', {
    method: 'post', muteHttpExceptions: true, contentType: 'application/json; charset=UTF-8',
    headers: {Authorization: 'Bearer ' + ScriptApp.getOAuthToken(), 'X-Upload-Content-Type': relay.mimeType || 'application/octet-stream'},
    payload: JSON.stringify({name: relay.fileName, parents: [folder.getId()]})
  });
  if (r.getResponseCode() >= 300) return {error: 'drive_init_failed', message: r.getContentText().slice(0, 300)};
  const headers = r.getHeaders();
  const loc = headers['Location'] || headers['location'];
  if (!loc) return {error: 'no_session_url'};
  return {uploadUrl: loc};
}
function handleFinalizeUpload(relay) {
  const id = relay.driveFileId;
  if (!id) return {error: 'missing_file_id'};
  try {
    DriveApp.getFileById(id).setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
    return {url: 'https://drive.google.com/file/d/' + id + '/view'};
  } catch (e) { return {error: 'finalize_failed', message: String(e)}; }
}
function handleTrashDriveFile(relay) {
  const id = relay.driveFileId;
  if (!id) return {ok: true};
  try { DriveApp.getFileById(id).setTrashed(true); } catch (e) { /* already gone — fine */ }
  return {ok: true};
}
function sweepOrphanUploads(team) {
  if (!team.filesRootFolderId) return;
  const known = {};
  listDocs('files').forEach(f => { if (f.driveFileId) known[f.driveFileId] = true; });
  const cutoff = Date.now() - 60 * 60000;
  (team.projects || []).forEach(p => {
    if (!p.driveFolderId) return;
    let folder;
    try { folder = DriveApp.getFolderById(p.driveFolderId); } catch (e) { return; }
    const it = folder.getFiles();
    while (it.hasNext()) {
      const f = it.next();
      if (known[f.getId()]) continue;
      if (f.getDateCreated().getTime() < cutoff) { try { f.setTrashed(true); } catch (e) { /* best effort */ } }
    }
  });
}
```

- [ ] **Step 3: Wire the orphan sweep into the daily cycle**

In `runCheck()`, right after the existing morning-summary block (the `if (hour >= 8 && hour < 10 ...)` block) and before the `// housekeeping: live events older than 2 days` line, add:

```js
    if (hour >= 3 && hour < 4 && props.getProperty('lastFileSweep') !== today) {
      sweepOrphanUploads(team);
      props.setProperty('lastFileSweep', today);
    }
```

(`team`, `hour`, `today`, and `props` are all already in scope at that point in `runCheck()`.)

- [ ] **Step 4: Syntax-check**

```bash
cd /home/claude/hq
cp apps-script/Code.gs /tmp/code-check.js
node --check /tmp/code-check.js
python3 -c "import json; json.load(open('apps-script/appsscript.json'))"
```

Expected: both commands exit with no output/errors.

- [ ] **Step 5: Commit**

```bash
git add apps-script/Code.gs apps-script/appsscript.json
git commit -m "$(cat <<'EOF'
Add Drive-backed file upload/finalize/trash endpoints to the worker

EOF
)

<attribution footer active at commit time>"
```

---

### Task 3: Deploy the updated worker and capture the web-app URL

**Files:** none (this task operates on the live Apps Script project only)

**Interfaces:**
- Produces: `WORKER_URL`, the live `/exec` URL for the deployed web app — needed as a literal string by Task 4.

- [ ] **Step 1: Push the updated files into the live Apps Script editor**

Using the Claude-in-Chrome browser tool, open `https://script.google.com/u/1/home/projects/1QaheGo7ig20vlqb8JlYmsm5-WHj33k4Rf3K57QEM2r27UANw5WhBBJSB/edit`. Using `window.monaco.editor.getModels()` and `model.setValue(...)`, replace the `Code.gs` model's content with the exact content of the local `apps-script/Code.gs` (from Task 2), and the `appsscript.json` model's content with the exact content of the local `apps-script/appsscript.json`. Save (Ctrl+S) and confirm "Saved to Drive".

- [ ] **Step 2: Verify the sync**

Check `model.getLineCount()` for each model against `wc -l apps-script/Code.gs` / `wc -l apps-script/appsscript.json` locally, and spot-check two or three line lengths (`model.getLineContent(n).length`) against the local file, exactly as done for the push-notification rollout. Do not dump full file content through `javascript_tool` (it false-positives on some string patterns).

- [ ] **Step 3: Deploy as a web app**

In the Apps Script editor: **Deploy → New deployment**. Select type **Web app**. Set **Execute as: Me (southies.co@gmail.com)** and **Who has access: Anyone**. Click **Deploy**. If prompted to re-authorize (expected, because of the new `drive.file` scope), click through **Review permissions → Allow**. Copy the resulting `/exec` URL — this is `WORKER_URL` for Task 4.

- [ ] **Step 4: Confirm a clean re-auth via `setup()`**

Run `setup()` from the Apps Script editor's function picker. Check **View → Executions** (or the inline execution log) and confirm it shows `Execution started` → a log line like `emails N, invites N` → `Execution completed`, with no error. This confirms the new scope authorized cleanly and the existing trigger still works.

- [ ] **Step 5: Record the URL**

Note the `WORKER_URL` value for use in Task 4 — no commit needed for this task (nothing in the repo changed).

---

### Task 4: index.html — data model, constants, and the `files` live listener

**Files:**
- Modify: `index.html`

**Interfaces:**
- Consumes: `state.db`, `esc()`, `member()`, `project()`, `first()`, `dayLabel()`, `OWNERS`, `render()`, existing `ic()`/`ICON` pattern.
- Produces: `state.files` (array, kept live via `onSnapshot`), `state.uploads` (object, keyed by local upload id), `state.filesTab`, `state.fileTag`, `state.allFilesSearch`, `FILE_TAGS`, `WORKER_URL`, `filesFor(key)`, `fileTagLabel(tag)`, `fmtSize(n)`, `relayCall(action, extra)` — all consumed by Tasks 5–9.

- [ ] **Step 1: Add the two new icons**

In the `ICON` object (next to the existing entries), add:

```js
  filedoc:'<path d="M6 3h9l5 5v13a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z"/><path d="M15 3v5h5"/>',
  linkic:'<path d="M9 15l6-6"/><path d="M13 6l1.5-1.5a3.5 3.5 0 0 1 5 5L18 11"/><path d="M11 18l-1.5 1.5a3.5 3.5 0 0 1-5-5L6 13"/>'
```

- [ ] **Step 2: Add `WORKER_URL` and `FILE_TAGS`**

Right after the existing `const OWNERS = [...]` line, add:

```js
const WORKER_URL = "<the /exec URL captured in Task 3>";
const FILE_TAGS = [["proposal","Proposal"],["plan","Plan"],["report","Report"],["brandbook","Brand book"],["logo","Logo"],["other","Other"]];
```

- [ ] **Step 3: Extend `state` and add helpers**

In the `state` object literal, add three fields (next to the existing `pushOn:false, pushBusy:false`):

```js
  filesTab:"tasks", fileTag:"all", allFilesSearch:"", files:[], uploads:{}
```

Right after the existing `const project = k => ...` line, add:

```js
const filesFor = k => state.files.filter(f => f.project === k);
function fileTagLabel(tag){ const hit = FILE_TAGS.find(([k]) => k === tag); return hit ? hit[1] : "Other"; }
function fmtSize(n){ if(!n) return ""; if(n < 1024*1024) return Math.round(n/1024) + " KB"; return (n/1024/1024).toFixed(1) + " MB"; }
```

- [ ] **Step 4: Add `relayCall`**

Right after `writeError(e)`, add:

```js
function relayCall(action, extra){
  return new Promise((resolve, reject) => {
    (async () => {
      try{
        const nonce = Math.random().toString(36).slice(2) + Date.now();
        await state.db.doc(`relay/${state.uid}`).set({email: state.email, action, nonce, ts: Date.now(), ...extra});
        const res = await fetch(WORKER_URL, {method:"POST", headers:{"Content-Type":"text/plain;charset=utf-8"}, body: JSON.stringify({uid: state.uid, nonce})});
        const data = await res.json();
        if(data.error) reject(new Error(data.error)); else resolve(data);
      }catch(e){ reject(e); }
    })();
  });
}
```

(`Content-Type: text/plain` is deliberate — it keeps the request in the CORS-safelisted category so the browser doesn't send a preflight `OPTIONS`, which Apps Script web apps don't handle.)

- [ ] **Step 5: Add the live listener**

In `boot()`, inside the `firebase.auth().onAuthStateChanged` callback, right after the existing `unsubs.push(db.collection("tasks").onSnapshot(...))` block, add:

```js
    unsubs.push(db.collection("files").onSnapshot(s => { state.files = s.docs.map(d => ({...d.data(), id:d.id})); render(); }, () => {}));
```

- [ ] **Step 6: Syntax-check**

```bash
cd /home/claude/hq
node -e "
const fs = require('fs');
const html = fs.readFileSync('index.html','utf8');
const m = html.match(/<script>([\s\S]*?)<\/script>/);
new Function(m[1]);
console.log('OK');
"
```

Expected: prints `OK` with no thrown error.

- [ ] **Step 7: Commit**

```bash
git add index.html
git commit -m "$(cat <<'EOF'
Add shared-files data model, live listener, and worker relay helper

EOF
)

<attribution footer active at commit time>"
```

---

### Task 5: index.html — Files tab on the project page (display + tag filter only)

**Files:**
- Modify: `index.html`

**Interfaces:**
- Consumes: `filesFor()`, `fileTagLabel()`, `fmtSize()`, `FILE_TAGS`, `ic()`, `emptyBox()`, `esc()`, `dayLabel()`, `first()`, `member()`.
- Produces: `filesSection(key)`, `fileRow(f)`, `uploadRow(u)` (rendered but not yet wired to real uploads — Task 7 fills in `runUpload`); a Tasks/Files switch on `pageProject()`.

- [ ] **Step 1: Add the seg switch and branch in `pageProject`**

Replace the body of `pageProject(key)` (the block starting `return \`${pageHead(p.name, "c-sun")}\`` through its closing backtick) so that after the existing `.phero` section and the `Edit details` actions row, it branches on `state.filesTab`:

```js
function pageProject(key){
  const p = project(key); if(!p) return emptyBox("Not found", "That project isn't on the board any more.");
  const ps = pstyle(key), its = state.tasks.filter(t => t.project === key), done = its.filter(t => t.status === "done"), open = its.filter(t => t.status !== "done").sort(sortTasks);
  const pct = its.length ? Math.round(done.length / its.length * 100) : 0;
  const people = [...new Set(open.flatMap(t => t.assignees || []))].filter(member);
  return `${pageHead(p.name, "c-sun")}
    <section class="phero" style="--fc:${ps.c}"><div><div class="eyebrow">${p.kind === "client" ? "Client" : p.kind === "own" ? "Our brand" : "Studio"}</div><h1 class="big" style="margin-top:6px">${pct}%</h1><div class="role">${done.length} of ${its.length} tasks done</div><div class="faces" style="margin-top:10px">${people.map(k => face(k)).join("")}</div></div><span class="fi" style="width:84px;height:84px;border:var(--b);border-radius:22px;background:var(--card);display:grid;place-items:center;box-shadow:var(--sh-sm)">${bigIcon(ps.i)}</span></section>
    ${state.canWrite ? `<div class="actions"><button type="button" class="cta white press" data-go="editproject" data-param="${esc(key)}">Edit details</button></div>` : ""}
    <div class="seg" role="group" aria-label="Section" style="align-self:flex-start"><button type="button" data-ptab="tasks" aria-pressed="${state.filesTab !== "files"}">Tasks</button><button type="button" data-ptab="files" aria-pressed="${state.filesTab === "files"}">Files</button></div>
    ${state.filesTab === "files" ? filesSection(key) : `${qaBlock({placeholder:`Add to ${p.name}`, project:key})}
    ${open.length ? group("Open", open) : emptyBox("All wrapped", "No open tasks on this project.")}
    ${group("Done", done.sort((a,b) => (b.doneAt||0) - (a.doneAt||0)).slice(0,8))}`}`;
}
```

- [ ] **Step 2: Add `filesSection`, `fileRow`, and `uploadRow`**

Right after `pageProject`, add:

```js
function filesSection(key){
  const all = filesFor(key), tag = state.fileTag || "all";
  const items = (tag === "all" ? all : all.filter(f => f.tag === tag)).slice().sort((a,b) => (b.addedAt||0) - (a.addedAt||0));
  const inflight = Object.values(state.uploads).filter(u => u.project === key);
  return `<div class="scrollx" aria-label="Filter by tag"><button type="button" class="pill" data-filetag="all" aria-pressed="${tag === "all"}">All</button>${FILE_TAGS.map(([k,l]) => `<button type="button" class="pill" data-filetag="${k}" aria-pressed="${tag === k}">${l}</button>`).join("")}</div>
    ${state.canWrite ? `<button type="button" class="cta press" data-addfile="${esc(key)}" style="align-self:flex-start">+ Add</button>` : ""}
    ${inflight.map(uploadRow).join("")}
    ${items.length ? `<ul class="tasks">${items.map(fileRow).join("")}</ul>` : (inflight.length ? "" : emptyBox("No files yet", "Proposals, plans, reports, brand books and logos for this project will show up here."))}`;
}
function fileRow(f){
  const thumbable = f.kind === "upload" && /^(image\/|application\/pdf)/.test(f.mimeType || "");
  const icon = f.kind === "link" ? "linkic" : "filedoc";
  const media = thumbable
    ? `<img src="https://drive.google.com/thumbnail?id=${esc(f.driveFileId)}&sz=w100" alt="" style="width:44px;height:44px;object-fit:cover;border-radius:10px;border:2px solid var(--ink);flex:none">`
    : `<span class="tick" style="cursor:default">${ic(icon,"")}</span>`;
  return `<li class="task" data-openfile="${esc(f.id)}"><div class="slide" style="cursor:pointer">${media}
    <div class="tbody"><div class="ttitle">${esc(f.name)}</div><div class="tmeta"><span class="chip">${esc(fileTagLabel(f.tag))}</span><span>${esc(first(member(f.addedBy)) || "Someone")} · ${esc(dayLabel(f.addedAt))}</span>${f.size ? `<span>${fmtSize(f.size)}</span>` : ""}</div></div>
  </div></li>`;
}
function uploadRow(u){
  if(u.status === "error") return `<div class="empty" style="text-align:left;padding:14px 16px"><b>Upload failed</b>${esc(u.name)}<div class="actions" style="margin-top:8px"><button type="button" class="btn press" data-retryupload="${esc(u.id)}">Retry</button><button type="button" class="btn danger press" data-cancelupload="${esc(u.id)}">Remove</button></div></div>`;
  return `<div class="nb" style="padding:12px 14px"><div class="tmeta" style="margin-bottom:6px">${esc(u.name)} · uploading…</div><div class="bar"><i data-uploadbar="${esc(u.id)}" style="width:${u.progress || 0}%;background:var(--sun)"></i></div></div>`;
}
```

- [ ] **Step 3: Wire the `data-ptab` and `data-filetag` clicks**

In the big `document.addEventListener("click", ...)` chain, add these two branches right after the existing `if((el = T("[data-mdone]"))){ ... }` line:

```js
  if((el = T("[data-ptab]"))){ state.filesTab = el.dataset.ptab; state.fileTag = "all"; render(true); return; }
  if((el = T("[data-filetag]"))){ state.fileTag = el.dataset.filetag; if(route().name === "allfiles") renderAllFilesResults(); else render(true); return; }
```

(`renderAllFilesResults` doesn't exist yet — it's added in Task 9. Since `data-filetag` doesn't appear anywhere until this task's own `filesSection`, and `route().name === "allfiles"` can't be true yet either, this branch is dead-but-harmless until Task 9 makes it real; leaving the reference in now avoids touching this same line again later.)

Also reset the two files-related state fields on every navigation, in `go()`:

```js
function go(name, param){ state.stack.push({name, param}); state.memberTab = "open"; state.filesTab = "tasks"; state.fileTag = "all"; render(true); window.scrollTo(0,0); animateIn(); }
```

- [ ] **Step 4: Syntax-check**

Run the same `new Function(...)` check as Task 4, Step 6. Expected: `OK`.

- [ ] **Step 5: Manual check (no files yet, so this checks the empty state and the switch)**

Using the Claude-in-Chrome browser tool at a phone-width viewport (390×844), open the live app once redeployed (after Step 6 commits and GitHub Pages updates), sign in, open any project, and confirm: the Tasks/Files switch appears under "Edit details", tapping **Files** shows the tag chips and the "No files yet" empty state, and tapping **Tasks** goes back to the normal task list.

- [ ] **Step 6: Commit**

```bash
git add index.html
git commit -m "$(cat <<'EOF'
Add the Files tab to project pages (display + tag filter)

EOF
)

<attribution footer active at commit time>"
```

---

### Task 6: index.html — Add-file sheet and "Save link" (fully working end to end)

**Files:**
- Modify: `index.html`

**Interfaces:**
- Consumes: `$()`, `esc()`, `FILE_TAGS`, `state.db`, `closeSheet()`, `toast()`, `writeError()`.
- Produces: `openFileSheet(projectKey)`, `saveFileForm(e)` — the link-saving path is fully functional after this task; the upload path is completed in Task 7.

- [ ] **Step 1: Add `openFileSheet`**

Right after `saveMember`/`removeMember`/`pageEditProject` region (anywhere near the other sheet-building functions — put it right after `deleteTask()`), add:

```js
/* ---------- add-file sheet ---------- */
function openFileSheet(projectKey){
  $("#panel").innerHTML = `
    <div class="phdr"><h2 id="sheet-title">Add to Files</h2><button type="button" class="circ c-sun press" data-close="1" aria-label="Close" style="width:40px;height:40px">${ic("x")}</button></div>
    <form id="fileform" style="display:flex;flex-direction:column;gap:16px" data-project="${esc(projectKey)}" novalidate>
      <div class="opts" role="group" aria-label="Type"><label><input type="radio" name="fs-mode" value="upload" checked><span>Upload file</span></label><label><input type="radio" name="fs-mode" value="link"><span>Save link</span></label></div>
      <div id="fs-upload-fields" class="fld"><span>File</span><input type="file" id="fs-file"></div>
      <div id="fs-link-fields" class="fld" hidden><span>Link</span><input type="url" class="txt" id="fs-url" placeholder="https://…" autocomplete="off"></div>
      <label class="fld"><span>Name</span><input type="text" class="txt" id="fs-name" maxlength="120" placeholder="e.g. Brand Book v2" autocomplete="off"></label>
      <label class="fld"><span>Tag</span><select id="fs-tag">${FILE_TAGS.map(([k,l]) => `<option value="${k}">${l}</option>`).join("")}</select></label>
      <div class="meta" id="fs-err" role="alert"></div>
      <div class="actions"><button type="submit" class="btn primary press">Save</button></div>
    </form>`;
  $("#sheet").hidden = false;
}
```

- [ ] **Step 2: Add mode-toggle and filename-autofill behavior**

In the existing `document.addEventListener("change", e => { ... })` handler, add (inside the existing function body, near the other `e.target.name === ...` checks):

```js
  if(e.target.name === "fs-mode"){ const up = e.target.value === "upload"; $("#fs-upload-fields").hidden = !up; $("#fs-link-fields").hidden = up; }
```

In the existing `document.addEventListener("input", e => { ... })` handler, add:

```js
  if(e.target.id === "fs-file"){ const nm = $("#fs-name"); const f = e.target.files && e.target.files[0]; if(nm && !nm.value.trim() && f) nm.value = f.name.replace(/\.[^.]+$/, ""); }
```

- [ ] **Step 3: Add `saveFileForm` (link path fully working; upload path queues to Task 7's `queueUpload`)**

Right after `openFileSheet`, add:

```js
async function saveFileForm(e){
  e.preventDefault();
  const form = e.target, project = form.dataset.project, err = $("#fs-err");
  const mode = (document.querySelector('input[name="fs-mode"]:checked') || {}).value || "upload";
  const tag = $("#fs-tag").value;
  let name = $("#fs-name").value.trim();
  if(mode === "link"){
    const url = $("#fs-url").value.trim();
    if(!/^https?:\/\//i.test(url)){ err.textContent = "Paste a valid link starting with http:// or https://"; $("#fs-url").focus(); return; }
    if(!name) name = url;
    try{
      await state.db.collection("files").doc().set({name, project, tag, kind:"link", url, driveFileId:null, mimeType:null, size:null, addedBy: state.meKey || "", addedByEmail: state.email || "", addedAt: Date.now()});
      closeSheet(); toast("Link saved");
    }catch(er){ writeError(er); }
    return;
  }
  const inp = $("#fs-file"), file = inp.files && inp.files[0];
  if(!file){ err.textContent = "Choose a file to upload."; return; }
  if(!name) name = file.name.replace(/\.[^.]+$/, "");
  closeSheet();
  queueUpload({file, project, name, tag});
}
```

- [ ] **Step 4: Wire the click and submit handlers**

In the click delegate chain, add (near the other `data-addfile`-style single-purpose branches, e.g. right after the `data-filetag` branch added in Task 5):

```js
  if((el = T("[data-addfile]"))){ openFileSheet(el.dataset.addfile); return; }
```

In `document.addEventListener("submit", e => { ... })`, add `fileform` to the chain:

```js
document.addEventListener("submit", e => { if(e.target.id === "tform") saveTask(e); else if(e.target.id === "cform") postComment(e); else if(e.target.id === "mform") saveMember(e); else if(e.target.id === "pform") saveProject(e); else if(e.target.id === "fileform") saveFileForm(e); });
```

- [ ] **Step 5: Syntax-check**

Same `new Function(...)` check. Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add index.html
git commit -m "$(cat <<'EOF'
Add the add-file sheet and working "save a link" flow

EOF
)

<attribution footer active at commit time>"
```

- [ ] **Step 7: Manual check (link path — fully testable without Drive/worker)**

Once redeployed, using the Claude-in-Chrome browser tool: open a project's Files tab, tap **+ Add**, switch to **Save link**, paste a real URL (e.g. a Google Doc link), give it a name, pick a tag, and Save. Confirm it appears immediately in the list with the right tag and name, and that tapping **Upload file** mode shows the file picker again with the link fields hidden.

---

### Task 7: index.html — Real Drive upload (progress, retry, worker integration)

**Files:**
- Modify: `index.html`

**Interfaces:**
- Consumes: `relayCall()` (Task 4), `uploadRow()` (Task 5), `state.uploads`, `render()`.
- Produces: `queueUpload(opts)`, `runUpload(id)`, `putToUploadUrl(url, file, onProgress)`, `renderUploadProgress(id)` — completes the upload path started in Task 6.

- [ ] **Step 1: Add the upload orchestration functions**

Right after `saveFileForm`, add:

```js
/* ---------- Drive upload ---------- */
let uploadSeq = 0;
function queueUpload({file, project, name, tag}){
  const id = "u" + (++uploadSeq);
  state.uploads[id] = {id, name, project, tag, file, progress:0, status:"uploading"};
  render(true);
  runUpload(id);
}
async function runUpload(id){
  const u = state.uploads[id]; if(!u) return;
  u.status = "uploading"; u.progress = 0; render(true);
  try{
    const {uploadUrl} = await relayCall("getUploadUrl", {project:u.project, fileName:u.name, mimeType:u.file.type || "application/octet-stream"});
    if(!uploadUrl) throw new Error("no upload url");
    const driveFileId = await putToUploadUrl(uploadUrl, u.file, pct => { const cur = state.uploads[id]; if(cur){ cur.progress = pct; renderUploadProgress(id); } });
    const {url} = await relayCall("finalizeUpload", {driveFileId});
    await state.db.collection("files").doc().set({
      name:u.name, project:u.project, tag:u.tag, kind:"upload", driveFileId,
      url: url || `https://drive.google.com/file/d/${driveFileId}/view`,
      mimeType:u.file.type || null, size:u.file.size || null,
      addedBy: state.meKey || "", addedByEmail: state.email || "", addedAt: Date.now()
    });
    delete state.uploads[id]; render(true); toast(`${u.name} uploaded`);
  }catch(e){ const cur = state.uploads[id]; if(cur){ cur.status = "error"; render(true); } }
}
function putToUploadUrl(url, file, onProgress){
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("PUT", url, true);
    xhr.setRequestHeader("Content-Type", file.type || "application/octet-stream");
    xhr.upload.onprogress = ev => { if(ev.lengthComputable) onProgress(Math.round(ev.loaded / ev.total * 100)); };
    xhr.onload = () => {
      if(xhr.status >= 200 && xhr.status < 300){ try{ resolve(JSON.parse(xhr.responseText).id); }catch(e){ reject(e); } }
      else reject(new Error("upload failed " + xhr.status));
    };
    xhr.onerror = () => reject(new Error("network error"));
    xhr.send(file);
  });
}
function renderUploadProgress(id){ const el = document.querySelector(`[data-uploadbar="${id}"]`); if(el) el.style.width = (state.uploads[id] ? state.uploads[id].progress : 0) + "%"; }
```

- [ ] **Step 2: Wire retry/cancel clicks**

In the click delegate chain, add (near the `data-addfile` branch from Task 6):

```js
  if((el = T("[data-retryupload]"))){ runUpload(el.dataset.retryupload); return; }
  if((el = T("[data-cancelupload]"))){ delete state.uploads[el.dataset.cancelupload]; render(true); return; }
```

- [ ] **Step 3: Syntax-check**

Same `new Function(...)` check. Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "$(cat <<'EOF'
Wire real Drive uploads with progress, retry, and a working relay call

EOF
)

<attribution footer active at commit time>"
```

- [ ] **Step 5: Manual check — a real upload end to end**

Once redeployed, using the Claude-in-Chrome browser tool: open a project's Files tab, tap **+ Add**, choose **Upload file**, pick a small real image (e.g. a PNG a few hundred KB), confirm the progress bar animates to 100%, and confirm the file then appears in the list with a thumbnail. Separately, check the Drive folder `Southie's HQ Files / <that project>` (via Drive, `/u/1/`) and confirm the uploaded file is there and shared "Anyone with the link — Viewer".

- [ ] **Step 6: Manual check — a failed upload shows Retry, with no orphan record**

Using `read_network_requests` or by throttling/blocking the network mid-upload (e.g. via Chrome devtools offline toggle through the browser tool, or by uploading a large-enough file and killing the tab's network right after starting), confirm the row switches to "Upload failed" with a working **Retry** button, and confirm no `files` Firestore document was created for it (check via the app — nothing appears in the list besides the failed-upload row, which is client-only state, not a Firestore doc).

---

### Task 8: index.html — Full-screen viewer, download/open-in-Drive, and Remove

**Files:**
- Modify: `index.html`

**Interfaces:**
- Consumes: `state.files`, `esc()`, `OWNERS`, `state.email`, `state.canWrite`.
- Produces: `openFileViewer(fileId)`, `closeViewer()`, `removeFile(fileId)`; a new `#viewer` element in the body markup.

- [ ] **Step 1: Add the `#viewer` element**

In the body markup, right after the existing `<div id="layer" class="layer" hidden></div>` line, add:

```html
<div id="viewer" class="layer" hidden></div>
```

- [ ] **Step 2: Add the viewer functions**

Right after `putToUploadUrl`/`renderUploadProgress`, add:

```js
/* ---------- file viewer ---------- */
function openFileViewer(fileId){
  const f = state.files.find(x => x.id === fileId); if(!f) return;
  if(f.kind === "link"){ window.open(f.url, "_blank", "noopener"); return; }
  state.confirmRemoveFile = false;
  const canRemove = state.canWrite && (f.addedByEmail === state.email || OWNERS.includes(state.email));
  const L = $("#viewer"); L.hidden = false; document.body.style.overflow = "hidden";
  L.innerHTML = `<div class="inner" style="gap:12px">
    <div class="pagehead"><button type="button" class="circ c-sun press" data-closeviewer="1" aria-label="Close">${ic("x")}</button><h2 style="font-size:14px">${esc(f.name)}</h2><span></span></div>
    <div style="border:var(--b);border-radius:18px;overflow:hidden;background:#000;box-shadow:var(--sh)"><iframe src="https://drive.google.com/file/d/${esc(f.driveFileId)}/preview" style="width:100%;height:60vh;border:0;display:block" allow="autoplay"></iframe></div>
    <div class="actions">
      <a class="btn press" href="https://drive.google.com/uc?export=download&id=${esc(f.driveFileId)}" target="_blank" rel="noopener">Download</a>
      <a class="btn press" href="${esc(f.url)}" target="_blank" rel="noopener">Open in Drive</a>
      ${canRemove ? `<button type="button" class="btn danger press" id="viewer-del" data-removefile="${esc(f.id)}">Remove</button>` : ""}
    </div></div>`;
}
function closeViewer(){ $("#viewer").hidden = true; $("#viewer").innerHTML = ""; document.body.style.overflow = ""; }
async function removeFile(fileId){
  const f = state.files.find(x => x.id === fileId); if(!f) return;
  const btn = $("#viewer-del");
  if(!state.confirmRemoveFile){ state.confirmRemoveFile = true; if(btn){ btn.textContent = "Tap again to remove"; btn.classList.add("confirm"); } return; }
  state.confirmRemoveFile = false;
  try{
    await state.db.doc(`files/${fileId}`).delete();
    if(f.kind === "upload" && f.driveFileId) relayCall("trashDriveFile", {driveFileId:f.driveFileId}).catch(() => {});
    closeViewer(); toast(`${f.name} removed`);
  }catch(er){ writeError(er); }
}
```

- [ ] **Step 3: Wire the clicks**

In the click delegate chain, add (near the other viewer-adjacent branches):

```js
  if((el = T("[data-openfile]"))){ openFileViewer(el.dataset.openfile); return; }
  if((el = T("[data-closeviewer]"))){ closeViewer(); return; }
  if((el = T("[data-removefile]"))){ removeFile(el.dataset.removefile); return; }
```

Place these **before** the existing `if((el = T("[data-open]")))` branch (task-sheet opener), since `[data-openfile]` and `[data-open]` are different attributes and won't collide, but keeping file-related branches grouped together avoids confusion later. Also add `Escape` support: in the existing `document.addEventListener("keydown", ...)` handler, extend the condition so Escape also closes the viewer:

```js
  if(e.key === "Escape"){ if(!$("#modal").hidden) $("#modal").hidden = true; else if(!$("#viewer").hidden) closeViewer(); else if(!$("#sheet").hidden) closeSheet(); else if(!$("#layer").hidden) closeLayer(); }
```

- [ ] **Step 4: Syntax-check**

Same `new Function(...)` check. Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "$(cat <<'EOF'
Add the full-screen file viewer, download/open-in-Drive, and Remove

EOF
)

<attribution footer active at commit time>"
```

- [ ] **Step 6: Manual check — viewer + permissions + removal**

Once redeployed: tap the uploaded PNG from Task 7 and confirm it opens full-screen with a visible preview, and Download/Open in Drive both work. Confirm the **Remove** button is visible (you're the uploader). Sign in as a different team member (or check via the app's own `state.canWrite`/`state.email` logic by reasoning about a second account) and confirm Remove does **not** appear for someone who didn't upload it and isn't Richard. As Richard (or the uploader), tap Remove twice and confirm the file disappears from the list and — after a few seconds for the worker to process — shows up in the Drive folder's trash. Also open the saved link from Task 6 and confirm it opens in a new tab, not the iframe viewer.

---

### Task 9: index.html — All-files page and Projects-page entry point

**Files:**
- Modify: `index.html`

**Interfaces:**
- Consumes: `state.files`, `project()`, `member()`, `first()`, `dayLabel()`, `fileTagLabel()`, `FILE_TAGS`, `esc()`, `pageHead()`, `emptyBox()`.
- Produces: `afBody()`, `pageAllFiles()`, `allFileRow(f)`, `renderAllFilesResults()`; router case `r.name === "allfiles"`; an "All files" entry button on `pageProjects()`.

- [ ] **Step 1: Add the All-files page functions**

Right after `pageProjects()`, add:

```js
function allFileRow(f){
  const p = project(f.project);
  const thumbable = f.kind === "upload" && /^(image\/|application\/pdf)/.test(f.mimeType || "");
  const icon = f.kind === "link" ? "linkic" : "filedoc";
  const media = thumbable
    ? `<img src="https://drive.google.com/thumbnail?id=${esc(f.driveFileId)}&sz=w100" alt="" style="width:44px;height:44px;object-fit:cover;border-radius:10px;border:2px solid var(--ink);flex:none">`
    : `<span class="tick" style="cursor:default">${ic(icon,"")}</span>`;
  return `<li class="task" data-openfile="${esc(f.id)}"><div class="slide" style="cursor:pointer">${media}
    <div class="tbody"><div class="ttitle">${esc(f.name)}</div><div class="tmeta"><span class="chip">${esc(fileTagLabel(f.tag))}</span><span>${esc(p ? p.name : "Removed project")}</span><span>${esc(first(member(f.addedBy)) || "Someone")} · ${esc(dayLabel(f.addedAt))}</span></div></div>
  </div></li>`;
}
function afBody(){
  const q = (state.allFilesSearch || "").trim().toLowerCase(), tag = state.fileTag || "all";
  let items = state.files.slice();
  if(tag !== "all") items = items.filter(f => f.tag === tag);
  if(q) items = items.filter(f => { const p = project(f.project); return [f.name, p ? p.name : "Removed project", first(member(f.addedBy))].join(" ").toLowerCase().includes(q); });
  items.sort((a,b) => (b.addedAt||0) - (a.addedAt||0));
  return `<div class="scrollx" aria-label="Filter by tag"><button type="button" class="pill" data-filetag="all" aria-pressed="${tag === "all"}">All</button>${FILE_TAGS.map(([k,l]) => `<button type="button" class="pill" data-filetag="${k}" aria-pressed="${tag === k}">${l}</button>`).join("")}</div>
    ${items.length ? `<ul class="tasks">${items.map(allFileRow).join("")}</ul>` : emptyBox("No files", q ? `Nothing found for "${state.allFilesSearch}".` : "Nothing uploaded yet.")}`;
}
function pageAllFiles(){
  return `${pageHead("All files","c-sun")}
    <label class="searchbox" for="af-input">${ic("search","")}<input type="text" id="af-input" autocomplete="off" placeholder="Search files, projects, people" value="${esc(state.allFilesSearch || "")}"></label>
    <div id="af-body">${afBody()}</div>`;
}
function renderAllFilesResults(){ const b = $("#af-body"); if(b) b.innerHTML = afBody(); }
```

- [ ] **Step 2: Add the router case and the Projects-page button**

In `render()`, right after the existing `else if(r.name === "project") html += pageProject(r.param);` line, add:

```js
  else if(r.name === "allfiles") html += pageAllFiles();
```

In `pageProjects()`, add an entry button right after the eyebrow/heading block and before `<div class="folders">`:

```js
function pageProjects(){
  return `${pageHead("Projects","c-sun")}
    <div><div class="eyebrow">Clients and our own brands</div><h1 class="big" style="margin-top:6px">Every project,<br>one shelf.</h1></div>
    <button type="button" class="cta white press" data-go="allfiles" style="align-self:flex-start">${ic("filedoc","")}All files</button>
    <div class="folders">${projects().map(p => { const its = state.tasks.filter(t => t.project === p.key); const done = its.filter(t => t.status === "done").length; const ps = pstyle(p.key); const fresh = its.some(t => (t.createdAt || 0) > Date.now() - 2 * 864e5); return `<button type="button" class="folder press" style="--fc:${ps.c}" data-go="project" data-param="${esc(p.key)}"><div class="fh"><span class="fi">${ic(ps.i, ps.i === "mark" ? "ic" : "")}</span><span class="fc">${its.length - done} open${fresh ? `<br><span class="badge-new">NEW</span>` : ""}</span></div><span class="fn">${esc(p.name)}</span><div class="bar"><i style="width:${its.length ? done / its.length * 100 : 0}%"></i></div></button>`; }).join("")}
      ${state.canWrite ? `<button type="button" class="folder press addcard" style="--fc:var(--card);align-items:center;text-align:center" data-go="editproject" data-param="new"><span class="plusbig">+</span><span class="fn">Add a project</span></button>` : ""}</div>`;
}
```

- [ ] **Step 3: Wire the search-as-you-type input**

In `document.addEventListener("input", e => { ... })`, add:

```js
  if(e.target.id === "af-input"){ state.allFilesSearch = e.target.value; renderAllFilesResults(); }
```

- [ ] **Step 4: Syntax-check**

Same `new Function(...)` check. Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "$(cat <<'EOF'
Add the All-files page with search and tag filtering

EOF
)

<attribution footer active at commit time>"
```

- [ ] **Step 6: Manual check**

Once redeployed: from the Projects page, tap **All files**, confirm every file from every project you've uploaded/linked so far appears with its project name, and typing in the search box filters live (without losing focus/cursor position) by name, project, or uploader. Tap a tag chip and confirm it filters too.

---

### Task 10: Full spec QA pass and cross-cutting checks

**Files:** none (verification only, using the Claude-in-Chrome browser tool against the live app)

**Interfaces:** none (this task only reads the live app and Firebase/Drive/Apps Script state built by Tasks 1–9)

- [ ] **Step 1: Upload one of each media type at phone width (390×844)**

Upload a small PDF, a small PPTX, and a PNG logo to the same project. Confirm the PDF and PNG show thumbnails in the row (PPTX shows the generic file icon, which is correct — Drive doesn't thumbnail Office files without opening them). Open each in the viewer and confirm the PDF and PNG preview inline; confirm the PPTX viewer at least loads Drive's preview (Drive can preview Office files even without a thumbnail).

- [ ] **Step 2: Save a Canva-style link and confirm it opens in a new tab**

From the add-file sheet, save a link (any real URL that isn't a Drive/PDF-embeddable page). Confirm tapping it in the file list opens a new tab rather than the in-app viewer.

- [ ] **Step 3: Confirm removal permissions end to end**

As the account that is NOT the uploader and is NOT Richard/an owner, open the viewer for a file someone else uploaded and confirm the Remove button is absent. Then, still as that account, attempt `state.db.doc('files/<that id>').delete()` directly in the browser console and confirm it throws a `permission-denied` error (proving the Firestore rule — not just the hidden button — is what's stopping it).

- [ ] **Step 4: Confirm project deletion doesn't touch files**

Create a throwaway test project, upload one file to it, then delete the project (via Edit details → Delete project). Confirm the file still appears on the All-files page, now labeled "Removed project".

- [ ] **Step 5: Confirm a killed upload fails cleanly**

Start uploading a reasonably large file (a few MB, so there's a window to interrupt it), then toggle the browser to offline mid-upload (via the Claude-in-Chrome browser tool's network controls, or by closing/reopening the tab). Confirm the row shows "Upload failed" with Retry, and confirm no matching `files` Firestore document exists (check the project's Files tab and the All-files page — nothing should appear besides the failed-upload placeholder, which vanishes once you dismiss or retry it).

- [ ] **Step 6: Confirm the relay rejects a forged call**

In the browser console while signed in, call `fetch(WORKER_URL, {method:"POST", headers:{"Content-Type":"text/plain"}, body: JSON.stringify({uid: state.uid, nonce:"not-the-real-nonce"})})` directly (skipping the `relayCall` helper's Firestore write). Confirm the JSON response is `{"error":"bad_nonce"}` (or `{"error":"missing_uid"}`/`{"error":"expired"}` depending on timing) — never a successful upload-URL or finalize response.

- [ ] **Step 7: Clean up test artifacts**

Delete the throwaway test project's file record (if it wasn't already covered by Step 4) and any test files/links created purely for this QA pass, so the live team doesn't see leftover clutter. Leave one real, intentionally-kept sample file per media type if useful for the team, otherwise remove everything test-only.

- [ ] **Step 8: Final report**

Summarize for Richard: what shipped, that each of the spec's testing-plan items passed, and the one-time nature of the Apps Script deployment (future `Code.gs` edits will need a **new deployment version**, not just a save — call this out explicitly since it's an easy step to forget).
