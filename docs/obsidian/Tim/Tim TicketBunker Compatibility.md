---
tags: [tim, architecture, compatibility]
status: initial-implementation
---

# Tim TicketBunker Compatibility

Related: [[Tim/Tim Overview]] · [[Tim/Tim Data Model]] · [[Tim/Tim Session Flow]]

This defines the boundary based on inspected TicketBunker source. The initial
implementation includes compatible references, branch-matching legacy metadata
discovery, JSONL history import, and versioned snapshot export. No TicketBunker
database consumer or live synchronization is implemented. Its separate audit may
revise storage; preserve public meaning over private layout.

## Human-led editor

Use Lua in Neovim plus a small shell launcher. TicketBunker's Python backend can
consume a versioned JSON contract; Tim does not need a matching implementation
language or a duplicate backend to interoperate.

The user edits the source. Keep code primary and an agent/context split in view.
Default Pi assistance uses read/search tools; advice can include proposed edits
for explicit application by the user. Applying a suggestion must check its base
content and preserve unsaved work. Notes, saves, and file navigation do not
automatically invoke the agent.

## Features to carry across

| Experience | Tim behavior |
| --- | --- |
| Notes beside numbered lines | Gutter marker and local thread anchored to a line/range |
| Comment on selected code | `:[range]comment`; save locally without sending |
| Ask about a selection/comment | `ask`/thread action creates an explicit submission |
| File-aware history | Retrieve matching file threads when the source buffer changes |
| Source mentions | Complete `@path`; resolve `@path:line` and `@[path with spaces]:line` |
| Agent citations | Same resolver as user mentions, with visible missing/stale targets |
| Branch context | Automatically observed Git context on each record, with no session binding |

The inspected editor's source-note overlays are derived from report citations.
Treat these imported notes as report-derived references with provenance, separate
from native Tim comments. Do not assume a shared editable line-comment table.

## Existing conventions verified in source

| TicketBunker source | Observed convention |
| --- | --- |
| `desktop/src/report.ts`: `sourceLinks` | `@path`, `@path:line`, `@[path]:line`; skips code spans |
| `desktop/src/TicketWorkspace.tsx`: `Quote` | `kind`, `category`, `scope`, `branch`, `path`, `line_start`, `line_end`, `text`, `unsaved` |
| `ticketbunker/coworker.py`: `_selected_reference` | Positive one-based ranges, project path resolution, category/scope agreement; current excerpt limit 2,400 characters |
| `ticketbunker/coworker.py`: `state` | File conversations filtered by category, scope and exact path within a ticket |
| `ticketbunker/coworker.py`: `command_chat` | Requires a resolved ticket; stores local messages and invokes a ticket coworker |
| `desktop/src/RepositoryWorkspace.tsx` | Repository-aware overlays; current annotations depend on matching branch/commit and clean source |
| `ticketbunker/bunkerdb.py`: `propose_report_publication` | Report scope uses `branch:<name>` alongside repository identity |

Chat scope is generally the selected branch name/report slug, not that report
database prefix. Never use those scope strings interchangeably.

## Reference compatibility

Preserve a full native snapshot. A legacy-compatible source quote has this shape:

```json
{
  "kind": "source",
  "category": "file",
  "scope": "feature/parser",
  "branch": "feature/parser",
  "path": "src/parser.py",
  "line_start": 42,
  "line_end": 46,
  "text": "selected source excerpt",
  "unsaved": true
}
```

The adapter must resolve the destination scope, project/repository and optional
ticket before using a legacy endpoint. Preserve repository-relative POSIX paths
and one-based ranges. Do not match files by basename or suffix. Render bracketed
mentions for spaces/Unicode. Structured ranges remain lossless even if a legacy
UI can only navigate to their first line.

Legacy quote limits must be handled explicitly when sending a selection: request
a smaller selection or present a bounded excerpt, retaining the original locally.
Draft/code-block text and ordinary email addresses must not become accidental
source attachments. Resolving a reference and sending source content are separate
actions.

## Automatic Git context

```sh
tim -s research                # Independent local work session
tim -s parser                  # Git context is observed automatically
tim --branch                   # Latest session used on the current branch
```

`--branch` only filters session selection, and requires an attached branch.
Plain `tim` resumes the chosen default within the folder/Git worktree; if none is chosen, ask for a name. Session history
can span branches, including detached HEAD or non-Git work, without a ticket.

Record `repository_id`, `worktree_id`, full Git ref, branch name, HEAD commit and
dirty state on comments, source references, submissions, and saved-work events.
Sessions can span branches while each record keeps its original context.
For an unborn branch, HEAD is null; for detached HEAD, the ref is null and the
commit is retained. Non-Git sessions mark `is_git=false` and omit ref/commit.

Branch names can change or be reused. Preserve old names/commits and observed
context history; never rewrite previous records or use a branch name as the
sole session/repository identifier. A Pi conversation-tree branch is unrelated
to a Git branch and has a separate ID.

On checkout changes, retain dirty buffers with their original provenance. Before
send or save, refresh Git context and detect stale buffers. Preserve the original
snapshot's Git context separately from the newly observed checkout. Include
snapshot and current context in the next explicit Pi submission.

## Indexing contract

Use an envelope with `schema_version`, `origin: "tim"`, stable `event_id`,
`session_id`, `created_at`, and `actor_role` (`user` or `assistant`). Payloads
include thread/message IDs, source references and immutable Git context. Include
explicitly mapped TicketBunker instance/repository IDs when connected and optional
ticket IDs. Local repository IDs must not be guessed from a remote URL or a folder
name and treated as TicketBunker IDs.

Index by these dimensions:

1. Repository and exact relative path, then captured line range.
2. Git context: branch/ref plus commit and worktree provenance.
3. Session, thread, message/entry ID, author role, and timestamp.
4. Optional TicketBunker repository and ticket associations.

Keep user comments, assistant replies, user source saves, and user-applied agent
suggestions as distinct event kinds. A save is not a Git commit; distinguish
saved buffer content hashes from HEAD. Viewing or indexing a message must not
change ticket status or attribute human edits to the agent.

A future explicit publish/import action can expose selected records to
TicketBunker. Its consumer must deduplicate by origin/event ID, retain the schema
version, and reject unsupported versions visibly. Private conversation history
is not automatically shared. Until that consumer exists, Tim's records remain
local and compatibility is limited to the verified reference conventions.

## Required compatibility checks before claiming support

- Named/default-session behavior and optional branch-usage selection.
- User and assistant mentions: spaces, Unicode, Windows separators, nonexistent
  targets, line ranges, and paths with identical basenames in different folders.
- Matching versus historical branch/revision annotations; unsaved snapshots.
- Branch switches, renames, deletion, detached HEAD, unborn branches and worktrees.
- File-context retrieval across sessions without mixing repositories or branches.
- Import replay deduplication and unknown schema-version handling.
- Existing TicketBunker consumers still work with their existing records and
  accepted source-quote payloads; no ticket is fabricated for an independent session.

Scope of evidence: local source inspection on 2026-09-19, headless Neovim tests
with real Git repositories and a Pi RPC fixture, and installed Pi 0.84.1 protocol
checks. No live TicketBunker database integration has been verified.
