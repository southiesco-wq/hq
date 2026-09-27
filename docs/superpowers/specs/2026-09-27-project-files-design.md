# Project Files — Design Spec

Date: 2026-09-27
Status: Approved by Richard James, ready for implementation

## Purpose

The team produces proposals, plans, reports, brand books, logos and other
client deliverables. Today these live scattered across people's own Drive
and devices. This adds a shared, permanent, team-visible Files section to
each project in Southie's HQ, plus a cross-project "All files" page.

## Requirements (as agreed)

- Every project gets a Files area, visible to the whole team, in the app.
- Files persist until explicitly removed (no auto-expiry).
- Anyone can upload a file or save a link; only the uploader or Richard
  (the Founder) can remove it.
- Category tags: Proposal, Plan, Report, Brand book, Logo, Other.
- Both uploaded files and external links (Canva, Figma, Google Docs) are
  supported.
- An "All files" page lists every file across all projects, searchable.
- Actual file bytes are stored in Google Drive (southies.co), not
  Firestore. Firestore holds metadata + Drive file ID / external URL.
- Drive sharing: uploaded files are set to "anyone with the link can
  view" so in-app preview works reliably on phones (including the
  home-screen PWA, where Drive's own sign-in prompt is unreliable).
- Removing a file moves it to Drive's trash (recoverable 30 days), not a
  permanent delete.
- Deleting a project does not touch its files; they remain in Drive and
  keep showing on the All-files page, tagged "Removed project".

## Data model

New Firestore collection `files/{fileId}`:

```
{
  name: string,              // display name
  project: string|null,      // project key, or null if project later removed
  tag: "proposal"|"plan"|"report"|"brandbook"|"logo"|"other",
  kind: "upload"|"link",
  driveFileId: string|null,  // set when kind === "upload"
  url: string,               // Drive webViewLink (upload) or the pasted URL (link)
  mimeType: string|null,     // set when kind === "upload"
  size: number|null,         // bytes, set when kind === "upload"
  addedBy: string,           // member key
  addedAt: number,           // ms epoch
  projectNameAtDelete: string|null  // filled in if the project is later deleted
}
```

Firestore rule (mirrors existing `tasks` pattern):

```
match /files/{fileId} {
  allow read: if isTeam();
  allow create: if isTeam();
  allow delete: if isTeam() &&
    (request.auth.token.email.lower() == resource.data.addedByEmail ||
     isOwner());
  allow update: if false; // files are immutable once created; removal is a delete
}
```

(We store `addedByEmail` alongside `addedBy` purely so the rule can check
it without a lookup — everything else keys off `addedBy`/member key.)

## Drive layout

One root folder in southies.co Drive: `Southie's HQ Files`, containing one
subfolder per project, named to match the project name at creation time
(renaming a project does not rename its Drive folder — cosmetic only).
The Apps Script worker creates a project's subfolder lazily, the first
time something is uploaded to it, and caches the folder ID on the
`config/team` project record so it doesn't need to search Drive again.

## Upload flow

Direct-to-Drive upload from the browser, so large files (50–200MB brand
books) don't pass through the Apps Script worker's request-size limits:

1. Client picks a file, sets name + tag, taps Upload.
2. Client calls the worker's `getUploadUrl` endpoint (see below) with
   project key, file name, and mime type. The worker verifies the
   caller's Firebase ID token against the team roster, creates the
   project's Drive folder if needed, and returns a Drive resumable-upload
   session URL for a file it has pre-created in that folder.
3. The browser PUTs the file bytes directly to that resumable session URL
   (Drive's API), with progress events driving the progress bar. This
   happens client-to-Google directly — the worker is out of the loop for
   the bytes themselves.
4. On completion, the client calls the worker's `finishUpload` endpoint
   with the Drive file ID. The worker sets the file's permission to
   "anyone with the link: viewer", fetches its webViewLink/size/mimeType,
   and writes the `files/{fileId}` Firestore record.
5. If step 3 fails or is abandoned, the client calls `finishUpload` with
   an `abort` flag so the worker deletes the orphaned Drive file. If the
   client vanishes without calling either, a nightly worker sweep (added
   to the existing hourly-ish trigger) deletes any Drive file older than
   1 hour with no matching Firestore record.

Saving a link never touches Drive: the client writes the `files/{fileId}`
record straight to Firestore (`kind: "link"`), since regular team members
already have Firestore create rights.

## Web endpoints (new)

The Apps Script worker currently only runs on a time trigger. This adds
a `doPost(e)` web app entry point (Apps Script "Deploy as web app",
execute as the script owner, accessible to "Anyone" — auth is enforced
inside by verifying the Firebase ID token passed in the body, the same
identity check the client already does for Firestore).

Actions dispatched by `e.parameter.action` / JSON body:
- `getUploadUrl` — { idToken, project, fileName, mimeType } → { uploadUrl, driveFileId }
- `finishUpload` — { idToken, driveFileId, project, fileName, tag } → writes Firestore record, or { idToken, driveFileId, abort: true } → deletes the orphaned file
- `removeFile` — { idToken, fileId } → checks uploader/owner, trashes the Drive file (if any) and deletes the Firestore record

Each verifies the ID token server-side (Google's tokeninfo endpoint,
same technique already usable via `UrlFetchApp`) rather than trusting a
bare email, so the endpoint can't be spoofed by someone crafting a
request outside the app.

## UI

**Project page:** a Tasks | Files segmented switch under the header
(same visual pattern as the existing Open | Done switch). Files view:
tag filter chips (All + the six tags), a "+ Add" button opening a sheet
with Upload file / Save link, and a reverse-chronological list of rows
(thumbnail or type icon, name, tag chip, "added by X · date", size).

**Viewer:** tapping an uploaded file opens a full-screen overlay that
embeds Google's preview (`https://drive.google.com/file/d/{id}/preview`
in an iframe) for PDFs/images/video/Office docs, with a top bar (name,
Download, Open in Drive, and Remove when permitted, with a confirm
step). Saved links open in a new tab instead of the overlay, since
Canva/Figma/Docs block iframe embedding.

**All files page:** a new "All files" entry point at the top of the
existing Projects page. Search box (matches name / project / added-by),
the same tag chips, reverse-chronological list with the project name
shown on each row ("Removed project" if the project no longer exists).

**Realtime:** `files` is read via `onSnapshot`, same as `tasks`, so
additions/removals show live for everyone without a refresh.

**Failure states:** a failed/interrupted upload shows an inline "Upload
failed" row with Retry (nothing partial is written to Firestore, so
retry is just re-running the flow); Drive-quota errors surface as a
plain-language toast.

## Testing plan

- Upload a PDF, a PPTX, and a PNG logo; preview each on a phone-width
  screen.
- Save a Canva link; confirm it opens in a new tab.
- Confirm a non-uploader team member cannot remove someone else's file
  (button hidden; direct call also rejected by the rule/worker check),
  and Richard can remove anything.
- Delete a project and confirm its files still show on the All-files
  page, marked "Removed project".
- Kill the network mid-upload and confirm the row shows "Upload failed"
  with a working Retry, and no orphan record is left in Firestore.

## Out of scope for this pass

- File versioning / replacing a file in place.
- Per-file comments (existing task comments are not extended to files).
- Editing a file's tag/name after creation (would be a small follow-up
  if wanted).
