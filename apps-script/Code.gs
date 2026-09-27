/**
 * Southie's HQ — email + calendar + push worker.
 * Runs inside southies.co@gmail.com every 5 minutes (see setup()).
 *  - Emails anyone newly assigned to a team task.
 *  - Creates / updates Google Calendar invites for tasks with a due date.
 *  - Sends a phone push on assignment, and deadline reminders (1 day / 1 hour / overdue).
 *  - Sends Richard a morning summary once a day.
 *  - Clears live-event records older than 2 days.
 */
const PROJECT_ID = 'southies-hq';
const APP_URL = 'https://southiesco-wq.github.io/hq/';
const SUMMARY_TO = 'richatdjames0@gmail.com';
const TZ = 'Asia/Kolkata';
const BASE = 'https://firestore.googleapis.com/v1/projects/' + PROJECT_ID + '/databases/(default)/documents';
const PRI = {1: 'P1 Urgent', 2: 'P2 High', 3: 'P3 Normal', 4: 'P4 Later'};
const PRI_BG = {1: '#FF5A36', 2: '#FFC83D', 3: '#86D4F5', 4: '#D8CCC6'};
const STATUS = {todo: 'To do', doing: 'In progress', waiting: 'Waiting on client', done: 'Done'};

/* ---------- run once by hand: installs the 5-minute schedule ---------- */
function setup() {
  ScriptApp.getProjectTriggers().forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('runCheck').timeBased().everyMinutes(5).create();
  runCheck();
}

/* ---------- main job ---------- */
function runCheck() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(20000)) return;
  try {
    const team = getDoc('config/team');
    if (!team) return;
    const members = team.members || [];
    const projects = team.projects || [];
    const byKey = {};
    members.forEach(m => byKey[m.key] = m);
    const projName = k => { const p = projects.find(x => x.key === k); return p ? p.name : 'None'; };
    const tasks = listDocs('tasks');
    const now = Date.now();
    let emails = 0, invites = 0;

    tasks.forEach(t => {
      if (t.status === 'done') return;
      const assignees = (t.assignees || []).filter(k => byKey[k]);
      const assigner = t.assignedBy || t.createdBy;
      const notified = (t.notified || []).slice();
      const patch = {};

      // (A) assignment emails + push
      const toSend = assignees.filter(k => notified.indexOf(k) < 0 && k !== assigner && byKey[k].email);
      toSend.forEach(k => {
        const byName = byKey[assigner] ? first(byKey[assigner]) : 'Someone';
        sendAssignmentEmail(t, byKey[k], byKey[assigner], assignees.filter(x => x !== k).map(x => first(byKey[x])), projName(t.project));
        sendPush(byKey[k], byName + ' assigned you a task', t.title);
        notified.push(k); emails++;
      });
      assignees.forEach(k => { if (k === assigner && notified.indexOf(k) < 0) notified.push(k); });
      if (notified.length !== (t.notified || []).length) patch.notified = notified;

      // (B) calendar invites
      if (t.dueAt && t.dueAt > now && assignees.length) {
        const cal = t.cal || {};
        const same = cal.status === 'sent' && cal.dueAt === t.dueAt && sameSet(cal.assignees || [], assignees);
        if (!same) {
          const guests = assignees.map(k => byKey[k].email).filter(Boolean);
          const eventId = syncEvent(t, cal.eventId, guests, projName(t.project));
          patch.cal = {status: 'sent', eventId: eventId, dueAt: t.dueAt, assignees: assignees};
          invites++;
        }
      }

      // (C) deadline push reminders — 1 day before, 1 hour before, and overdue
      if (t.dueAt && assignees.length) {
        const msLeft = t.dueAt - now;
        let flags = Object.assign({}, t.pushFlags || {});
        let changed = false;
        if (flags.dueAt !== t.dueAt) { flags = {dueAt: t.dueAt}; changed = true; }
        const when = Utilities.formatDate(new Date(t.dueAt), TZ, 'EEE d MMM, h:mm a');
        if (!flags.day && msLeft > 0 && msLeft <= 24 * 60 * 60000) {
          assignees.forEach(k => sendPush(byKey[k], 'Due tomorrow', t.title + ' — ' + when));
          flags.day = true; changed = true;
        }
        if (!flags.hour && msLeft > 0 && msLeft <= 60 * 60000) {
          assignees.forEach(k => sendPush(byKey[k], 'Due in an hour', t.title));
          flags.hour = true; changed = true;
        }
        if (!flags.overdue && msLeft <= 0) {
          assignees.forEach(k => sendPush(byKey[k], 'Overdue', t.title + ' was due ' + when));
          flags.overdue = true; changed = true;
        }
        if (changed) patch.pushFlags = flags;
      }

      if (Object.keys(patch).length) patchDoc('tasks/' + t._id, patch);
    });

    // (C) morning summary, once per day between 8 and 10 AM IST
    const hour = +Utilities.formatDate(new Date(), TZ, 'H');
    const today = Utilities.formatDate(new Date(), TZ, 'yyyy-MM-dd');
    const props = PropertiesService.getScriptProperties();
    if (hour >= 8 && hour < 10 && props.getProperty('lastSummary') !== today) {
      sendSummary(tasks, byKey);
      props.setProperty('lastSummary', today);
    }

    if (hour >= 3 && hour < 4 && props.getProperty('lastFileSweep') !== today) {
      sweepOrphanUploads(team);
      props.setProperty('lastFileSweep', today);
    }

    // housekeeping: live events older than 2 days
    listDocs('events').forEach(e => { if (e.ms && now - e.ms > 2 * 864e5) deleteDoc('events/' + e._id); });
    console.log('emails ' + emails + ', invites ' + invites);
  } finally {
    lock.releaseLock();
  }
}

/* ---------- email ---------- */
function sendAssignmentEmail(t, to, by, others, project) {
  const due = t.dueAt ? Utilities.formatDate(new Date(t.dueAt), TZ, 'EEE d MMM, h:mm a') + ' (IST)' : 'No due date';
  const pr = t.priority || 3;
  const byName = by ? first(by) : 'Someone';
  const also = others.length ? others.join(', ') : 'Just you';
  const notes = t.notes ? String(t.notes) : '';
  const text = 'Hi ' + first(to) + ',\n\n' + byName + " assigned you a task on Southie's HQ.\n\n" + t.title +
    '\nPriority: ' + PRI[pr] + '\nProject: ' + project + '\nStatus: ' + (STATUS[t.status] || 'To do') + '\nDue: ' + due +
    '\nAlso on it: ' + also + (notes ? '\n\nNotes: ' + notes : '') + "\n\nOpen Southie's HQ: " + APP_URL + "\n\n— Southie's HQ";
  const html =
    '<div style="background:#FFF4EA;padding:24px 12px;font-family:Arial,Helvetica,sans-serif;color:#1B0D10">' +
    '<div style="max-width:520px;margin:0 auto;background:#fff;border:3px solid #1B0D10;border-radius:20px;overflow:hidden">' +
    '<div style="background:#C8462A;background:linear-gradient(135deg,#4A1A20,#B43B25,#DC6A2D);padding:18px 22px;color:#fff">' +
    '<div style="font-size:12px;letter-spacing:3px;font-weight:bold">SOUTHIE\'S HQ</div>' +
    '<div style="font-size:22px;font-weight:bold;margin-top:6px">You\'ve got a new task</div></div>' +
    '<div style="padding:22px"><p style="margin:0 0 14px;font-size:15px">Hi ' + esc(first(to)) + ', <b>' + esc(byName) + '</b> assigned you a task.</p>' +
    '<div style="border:2px solid #1B0D10;border-radius:14px;padding:14px 16px;background:#FFF4EA">' +
    '<div style="font-size:17px;font-weight:bold;margin-bottom:10px">' + esc(t.title) + '</div>' +
    '<div style="font-size:14px;line-height:1.7"><span style="display:inline-block;background:' + PRI_BG[pr] + ';color:' + (pr === 1 ? '#fff' : '#1B0D10') +
    ';border:2px solid #1B0D10;border-radius:99px;padding:0 9px;font-weight:bold;font-size:12px">' + PRI[pr] + '</span><br>' +
    '<b>Project:</b> ' + esc(project) + '<br><b>Due:</b> ' + esc(due) + '<br><b>Also on it:</b> ' + esc(also) + '</div>' +
    (notes ? '<p style="margin:10px 0 0;font-size:14px;color:#4A3A3D">' + esc(notes) + '</p>' : '') + '</div>' +
    '<p style="margin:20px 0 6px"><a href="' + APP_URL + '" style="display:inline-block;background:#FFC83D;color:#1B0D10;border:3px solid #1B0D10;border-radius:14px;padding:12px 20px;font-weight:bold;text-decoration:none">Open Southie\'s HQ</a></p>' +
    '<p style="margin:14px 0 0;font-size:12px;color:#8A7A7C">You\'re getting this because you were assigned a task on Southie\'s HQ.</p></div></div></div>';
  MailApp.sendEmail({to: to.email, subject: 'New task for you: ' + t.title, body: text, htmlBody: html, name: "Southie's HQ"});
}

function sendSummary(tasks, byKey) {
  const now = Date.now();
  const endOfDay = new Date(Utilities.formatDate(new Date(), TZ, "yyyy-MM-dd'T'23:59:59") + '+05:30').getTime();
  const open = tasks.filter(t => t.status !== 'done');
  const who = t => (t.assignees || []).map(k => byKey[k] ? first(byKey[k]) : '').filter(String).join(', ') || 'Nobody';
  const overdue = open.filter(t => t.dueAt && t.dueAt < now);
  const today = open.filter(t => t.dueAt && t.dueAt >= now && t.dueAt <= endOfDay);
  const line = t => '• ' + t.title + ' (' + who(t) + ', ' + Utilities.formatDate(new Date(t.dueAt), TZ, 'EEE d MMM h:mm a') + ')';
  const body = "Good morning Richard,\n\nOverdue (" + overdue.length + '):\n' + (overdue.map(line).join('\n') || '• Nothing overdue') +
    '\n\nDue today (' + today.length + '):\n' + (today.map(line).join('\n') || '• Nothing due today') +
    '\n\nOpen tasks on the board: ' + open.length + "\n\nOpen Southie's HQ: " + APP_URL;
  MailApp.sendEmail({to: SUMMARY_TO, subject: "Southie's HQ · " + overdue.length + ' overdue, ' + today.length + ' due today', body: body, name: "Southie's HQ"});
}

/* ---------- push (FCM) ---------- */
function sendPush(mem, title, body) {
  const tokens = (mem && mem.pushTokens) || [];
  if (!tokens.length) return;
  const endpoint = 'https://fcm.googleapis.com/v1/projects/' + PROJECT_ID + '/messages:send';
  const authHeader = 'Bearer ' + ScriptApp.getOAuthToken();
  const bad = [];
  tokens.forEach(tok => {
    const payload = {message: {token: tok, notification: {title: title, body: body},
      webpush: {fcmOptions: {link: APP_URL}, notification: {icon: APP_URL + 'icon-192.png'}}, data: {url: APP_URL}}};
    let r;
    try {
      r = UrlFetchApp.fetch(endpoint, {method: 'post', contentType: 'application/json', muteHttpExceptions: true,
        headers: {Authorization: authHeader}, payload: JSON.stringify(payload)});
    } catch (e) { return; }
    const code = r.getResponseCode();
    if (code === 404 || code === 400) {
      const txt = r.getContentText();
      if (txt.indexOf('UNREGISTERED') >= 0 || txt.indexOf('NOT_FOUND') >= 0 || txt.indexOf('INVALID_ARGUMENT') >= 0) bad.push(tok);
    }
  });
  if (bad.length) removePushTokens(mem.key, bad);
}
function removePushTokens(memberKey, badTokens) {
  try {
    const team = getDoc('config/team');
    if (!team || !team.members) return;
    const members = team.members.map(m => {
      if (m.key !== memberKey || !m.pushTokens) return m;
      return Object.assign({}, m, {pushTokens: m.pushTokens.filter(t => badTokens.indexOf(t) < 0)});
    });
    patchDoc('config/team', {members: members});
  } catch (e) { /* best-effort cleanup */ }
}

/* ---------- files (Drive + web endpoint) ---------- */
const FILES_FOLDER_NAME = "Southie's HQ Files";
const RELAY_MAX_AGE_MS = 30000;
// Keep in sync with OWNERS in index.html and isOwner() in firestore.rules —
// owners are always team members even if they're not in config/team.emails.
const OWNER_EMAILS = ["richatdjames0@gmail.com", "southies.co@gmail.com"];

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
    const isTeamMember = OWNER_EMAILS.indexOf(email) >= 0 || (team && (team.emails || []).indexOf(email) >= 0);
    if (!isTeamMember) return jsonOut({error: 'not_team'});
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

/* ---------- calendar ---------- */
function syncEvent(t, eventId, guests, project) {
  const cal = CalendarApp.getDefaultCalendar();
  const start = new Date(t.dueAt - 30 * 60000), end = new Date(t.dueAt);
  const title = 'Due: ' + t.title;
  const desc = PRI[t.priority || 3] + ' · ' + project + (t.notes ? '\n' + t.notes : '') + "\n\nUpdate or comment on Southie's HQ: " + APP_URL;
  let ev = null;
  if (eventId) {
    ev = cal.getEventById(eventId) || cal.getEventById(eventId + '@google.com');
  }
  if (ev) {
    ev.setTime(start, end); ev.setTitle(title); ev.setDescription(desc);
    const current = ev.getGuestList().map(g => g.getEmail().toLowerCase());
    guests.forEach(g => { if (current.indexOf(g.toLowerCase()) < 0) ev.addGuest(g); });
    current.forEach(g => { if (guests.map(x => x.toLowerCase()).indexOf(g) < 0) ev.removeGuest(g); });
    return eventId;
  }
  ev = cal.createEvent(title, start, end, {description: desc, guests: guests.join(','), sendInvites: true});
  ev.removeAllReminders(); ev.addPopupReminder(1440); ev.addPopupReminder(60); ev.addEmailReminder(1440);
  return ev.getId();
}

/* ---------- Firestore REST ---------- */
function req(method, url, payload) {
  const opt = {method: method, muteHttpExceptions: true, contentType: 'application/json',
    headers: {Authorization: 'Bearer ' + ScriptApp.getOAuthToken(), 'X-Goog-User-Project': PROJECT_ID}};
  if (payload) opt.payload = JSON.stringify(payload);
  const r = UrlFetchApp.fetch(url, opt);
  const code = r.getResponseCode();
  if (code === 404) return null;
  if (code >= 300) throw new Error('Firestore ' + method + ' ' + code + ': ' + r.getContentText().slice(0, 300));
  const txt = r.getContentText();
  return txt ? JSON.parse(txt) : {};
}
function getDoc(path) { const d = req('get', BASE + '/' + path); return d ? fromFields(d.fields || {}) : null; }
function listDocs(coll) {
  let out = [], token = '';
  do {
    const d = req('get', BASE + '/' + coll + '?pageSize=300' + (token ? '&pageToken=' + encodeURIComponent(token) : ''));
    ((d && d.documents) || []).forEach(doc => { const o = fromFields(doc.fields || {}); o._id = doc.name.split('/').pop(); out.push(o); });
    token = d && d.nextPageToken;
  } while (token);
  return out;
}
function patchDoc(path, data) {
  const mask = Object.keys(data).map(k => 'updateMask.fieldPaths=' + encodeURIComponent(k)).join('&');
  return req('patch', BASE + '/' + path + '?' + mask, {fields: toFields(data)});
}
function deleteDoc(path) { return req('delete', BASE + '/' + path); }
function toFields(o) { const f = {}; Object.keys(o).forEach(k => f[k] = toValue(o[k])); return f; }
function toValue(v) {
  if (v === null || v === undefined) return {nullValue: null};
  if (typeof v === 'boolean') return {booleanValue: v};
  if (typeof v === 'number') return Number.isInteger(v) ? {integerValue: String(v)} : {doubleValue: v};
  if (typeof v === 'string') return {stringValue: v};
  if (Array.isArray(v)) return {arrayValue: {values: v.map(toValue)}};
  return {mapValue: {fields: toFields(v)}};
}
function fromFields(f) { const o = {}; Object.keys(f).forEach(k => o[k] = fromValue(f[k])); return o; }
function fromValue(v) {
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('nullValue' in v) return null;
  if ('timestampValue' in v) return new Date(v.timestampValue).getTime();
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(fromValue);
  if ('mapValue' in v) return fromFields(v.mapValue.fields || {});
  return null;
}

/* ---------- helpers ---------- */
function first(m) { return m && m.name ? String(m.name).split(' ')[0] : ''; }
function sameSet(a, b) { return a.length === b.length && a.every(x => b.indexOf(x) >= 0); }
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c])); }
