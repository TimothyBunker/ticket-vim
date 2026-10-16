# tim

A persistent project conversation, accessed directly through Neovim.

Status: first implementation is available in `lua/tim`, `plugin/tim.lua`, and
`bin/tim`. See `README.md` for supported commands and current limits. Neovim-only
support, Pi as the agent backend, and Lua with a small shell launcher are confirmed.
Unimplemented packaging and richer integration details below remain proposals.

## Consolidated editor contract

Source buffers stay left; a single agent panel renders Chat, Comments, or Diffs.
All views share one input. Review sets the input's explicit intent; blank text
uses the default review instruction, custom text becomes its instructions.
Cancel review clears that intent without losing text. Enter sends to Pi; only
Save note saves locally. Progress, errors, Cancel, and Retry are visible. A
cancellation during connection prevents a later prompt from being sent.

Native selections become durable context without opening a popup. Context shows
its file/ranges, and stale selections are rejected before sending. Each request
includes the full saved/unsaved buffer (256 KB maximum; 400 KB total prompt).
Snapshot/Git provenance remains independent of optional ticket metadata.

## Structured editor actions and durable decisions

Tim explicitly loads agent/editor.mjs with Pi's read/search tools. Automatic
extension/skill/template discovery stays disabled. editor_comment publishes a
finding or refreshes an existing comment_id; editor_propose_diff publishes a
complete diff linked to that ID. Results carry a versioned details.tim payload
in Pi's authoritative toolResult entries. Only successful results from these
exact tool names and matching tool-call IDs are accepted. No editor tool writes
source or runs a command. The installed runtime is checked via a model-free RPC
smoke test, and tool execution is tested independently.

Comments retain stable identity, source snapshot, originating request, discussion
thread and resolved state. Diffs share comment_id and retain applied/rejected
states from explicit work events. Old prose findings and fenced diffs are read as
legacy data, preserving earlier sessions. Their inferred links use file/range and
branch; new structured links are explicit. Unanchorable findings report errors.

Comments show open/proposal ready/applied/resolved/outdated. Green source diamonds
open Diffs. That view lists every proposal, shows the selected colored diff and
only applicable actions: Apply, Reject, Undo, Refresh, and Comment. Refresh fills
the shared input and requires Enter; it never replaces existing unsent text.

Apply validates every target against the displayed buffer snapshots/change ticks
before changing any buffer. It never saves. Work records store the proposal ID,
before/after source snapshots, actor, paths and Git context. Undo validates all
current contents against the application outputs before reversing it, including
after restart. Newer work or another branch blocks Undo. Rejection is metadata
only. Unsupported/outdated proposals stay visible without an Apply action.

## Navigation and request lifecycle

File tabs share the agent panel. Source citations navigate and briefly highlight
locations. Historical comments only get markers at verified anchors; outdated
findings remain visible in Comments with Refresh. Saving, file navigation and
selection never run the agent. The launcher defaults to expanded two-space tabs,
including Python, and source quit exits the editor with normal save confirmation.

Requests persist before RPC dispatch; failed/uncertain sends never retry on their
own. Explicit Retry keeps selected focus and refreshes source context. Cancel
handles both connection and accepted-request phases. Streaming updates chat but
preserves unsent input; reply follow is disabled while reading chat history.

## Product direction

`tim` is the portable editing and agent-interaction half of the user's broader
TicketBunker workflow. Neovim supplies the editor, Pi supplies the agent runtime,
and tim supplies the project-session experience. Local work sessions are useful
independently of TicketBunker and need not aim to complete a ticket. A session can
explore an idea, span several tickets, or have no ticket association at all.
TicketBunker links provide optional context; they do not own session lifecycle.

The person is the primary worker. Source editing stays central, with a compact
agent/session split alongside it. The agent explains, reviews, and suggests;
opening a file, saving code, or recording a comment does not start agent work.
Start Pi with a read/search tool allowlist for the default assistance mode.
Suggestions can be reviewed and applied explicitly in the editor against their
captured base content. Broader agent execution is an explicit later capability.

Ship a ready-to-use editor configuration behind a `tim` launcher. Support loading
the same Lua modules into an existing Neovim setup for users who prefer it.
The packaged editor should include coherent file navigation, search, ordinary
editing, and session views with minimal setup.

## Interaction model

Each project can have multiple named persistent local sessions, with one active
in an editor instance. Plain `tim` resumes the saved default session in the
current project, asking for a name if none has been selected. `tim -s <name>` opens
the named session or creates it if absent. The session records submissions,
replies, and agent activity in time order. File views filter that same session
rather than creating separate conversations. Ticket completion does not close or
reset a session.

The user writes a question or thought in an ordinary editable draft buffer, adds
references, and explicitly submits it. Saving a draft does not send it. Agent
responses stream into a separate transcript buffer, preserving drafts and cursor
position.

Example workflow:

1. Open `src/parser.go`, select a function, and run `:'<,'>ask`.
2. A draft opens with a reference to that file and selection attached.
3. Write “Why does this reject an empty value?” and run `:TimSend`.
4. The reply appears in the session with a link back to the selected source.
5. Return later and run `:TimFile` to see exchanges associated with this file.

Messages can reference several files. A reply belongs to its submission through
a stable parent ID, so it stays paired with the question in filtered views.

## Proposed commands

```sh
tim                         # Resume this project's saved default session
tim -s parser               # Open or create the project's "parser" session
tim -s "database redesign"  # Session names may contain spaces
tim -s parser --branch      # Open parser, observing the current Git branch
tim --branch                # Latest session used on this Git branch
```

Session names are unique within a project and resolve to stable local session
IDs plus exact Pi session identities. Names are labels, not filesystem paths.
Persist `last_used_at` on successful open/resume and accepted user submissions;
break timestamp ties deterministically by session ID. Opening a file-filtered
view does not select another session. A missing `-s` value is a usage error.
Outside Git, use the working folder as the session scope.

Git context is observed automatically, without a flag or session binding. Each
record keeps its original context as the checkout changes. `--branch` optionally
selects the most recently used session on the current attached branch; with `-s`,
the explicit name wins. It never creates, checks out, or locks a branch. Plain
`tim` resumes the saved default; `tim -s name` chooses it. With no default, ask for a name. Pi conversation-tree branches
are separate from observed Git branches.

| Command | Behavior |
| --- | --- |
| `:Tim` | Open the project session in the current window. |
| `:TimSplit` | Open the session beside the source file. |
| `:TimFile` | Show exchanges referencing the current source file. |
| `:TimAll` | Restore the complete chronological session view. |
| `:[range]ask` | Send the supplied question about the current line or selection; without text, open a draft. |
| `:[range]comment` | Save a local line/range comment without invoking Pi. |
| `:[range]TimRef` | Attach another source reference to the active draft. |
| `:TimSend` | Submit the draft and its attached references. |
| `:TimStop` | Request cancellation of the current agent turn. |

Show comment markers beside numbered source lines. A comment opens a thread in
the side pane with its source snapshot and replies. Selecting Ask from a thread
submits it to the current session; ordinary comments remain usable without Pi.
Typing `@` in a draft completes project paths. Both user and agent messages accept
`@path`, `@path:line`, and TicketBunker's `@[path with spaces]:line` syntax.
Selected ranges are structured metadata; preserve the compatible start-line link
when rendering them for TicketBunker. Live markers use extmarks; historical
references retain path, range, excerpt, revision, and unsaved state.

The file context pane follows the last active source buffer and retrieves exact
repository/path matches, prioritizing the current session, matching Git context,
and overlapping lines. Other-session or other-branch results are labelled and
explicitly expandable. Moving to a file does not submit its contents to Pi.
Capture the full current buffer and selected context only when the user sends a
question; keep the target file and attached references visible. Use deterministic file/range lookup initially.

Full-window and split views use the same session. Switching views preserves the
draft, active request, and source-file target. Enter or `gf` on a reference opens
the source at its location; mouse navigation can use the same reference resolver.

With the startup integration enabled, running plain `nvim` without file arguments
opens the session for the current project. Explicit files, stdin, and recovery
startup take precedence. Outside Git, use the working folder.
The packaged `tim` launcher enables this behavior in its own editor configuration;
plugin users can enable it in their normal Neovim configuration.

Project discovery starts from the source file or startup working directory. Use
the Git worktree root when available, or an explicitly initialized directory for
non-Git projects. Separate worktrees get separate sessions by default.

## Implementation direction

Implementation language: Lua, running inside Neovim. The plugin owns
buffers, mappings, selections, links, window layout, draft persistence, and the
file/time index. It communicates directly with Pi through asynchronous job
channels. Pi owns model access, tool execution, conversation persistence, and
context compaction.

Pi's existing session and RPC interfaces remove the immediate need for the
previously proposed Go core. Reconsider a separate process only if background
operation or attachment from multiple editors justifies it. A small shell
launcher is sufficient for the first Linux package.

```text
Neovim + tim Lua modules
    |              |
drafts/index   JSONL over stdio
                   |
             pi --mode rpc
                   |
           Pi session + tools
```

Start one Pi subprocess for the active project, with an exclusive tim
project-session lock and a clear message when another tim instance owns it.
The lock does not control unrelated Pi clients; do not concurrently open the same
session in an external client. Multi-editor attachment is a later extension.

Pi's native session is the source of truth for conversation history. Persist the
exact Pi session identity/path per project and resume it explicitly. Store tim's
drafts, submission records, and file-reference metadata separately under the
user's application-data directory, linking accepted submissions to stable Pi
entry IDs. Rebuild the time/file index from those records and Pi's entries.
Recover the full history through `get_entries`, including pre-compaction entries;
preserve branch ancestry so the default transcript follows the active branch.

Render the transcript as a Markdown-like buffer; do not parse user-edited prose
to recover authoritative session state. Save drafts separately, and handle
interrupted metadata writes without losing earlier records. After a disconnect,
reconcile submissions against Pi's persisted entries before offering a retry;
never blindly resend a prompt whose acceptance is uncertain.

Each submission records:

- Stable message ID, timestamp, and project-session ID.
- Text and explicit parent/reply relationships.
- References containing project-relative path, selected line range, and captured
  text from the buffer, including unsaved edits.
- A content hash and available revision information to detect stale references.
- Request status: queued, running, completed, failed, or cancelled.
- Repository/worktree identity and observed Git ref, branch name, HEAD commit,
  and dirty/unsaved state at capture time, without binding the session to Git.

Comments and source-save events also retain that Git context, allowing file and
branch indexing without requiring a ticket. Keep each comment/thread ID stable,
with explicit author role and timestamps. Track user saves and explicitly applied
agent suggestions separately; do not infer authorship from the branch owner.

File locations change. Retain the original excerpt and location, try to relocate
the excerpt in the current file, and label ambiguous or missing targets rather
than silently claiming an exact match.

Use Neovim extmarks to track reference positions as loaded buffers change.
Extmarks complement the persisted excerpts and revision information; references
must still be resolved after reopening a file or editing it outside Neovim.

Indexing the complete history does not mean sending it all on every request.
Send each new prompt and its explicit references to the resumed Pi session;
Pi manages its existing context and compaction. Keep UI filtering separate from
model context: opening a file view does not reset or replace the conversation.

## Agent boundary

Use `pi --mode rpc`, launched with the project as its working directory and an
explicit session path when resuming. Parse strict LF-delimited JSON records,
handling records split across reads and multiple records arriving together.
Invoke the executable with an argument list rather than shell interpolation.

The adapter maps `prompt`, streaming message/tool events, `get_state`,
`get_entries`, and `abort` onto the editor. A successful prompt response means
accepted, not completed. Use `agent_settled` and session state to distinguish
completion from intermediate `agent_end` events, retries, and compaction.

Render Pi extension select/confirm/input/editor requests through Neovim and send
the matching `extension_ui_response`. Preserve extension-provided permission
decisions. Pi TUI-specific custom widgets are not available through RPC and need
an explicit alternative if an integration relies on them.

Serialize submitted turns initially. Keep visible request status and preserve a
failed submission for retry. A cancellation request is not a completed
cancellation until the backend confirms it or exits.

## Packaging and TicketBunker integration

Package a tested Neovim runtime, the tim Lua configuration, and a pinned Pi
runtime with its required assets. Use `NVIM_APPNAME=tim` and an explicitly loaded
bundled configuration to keep editor state independent of personal Neovim config.
The packaged experience should start without downloading plugins on first launch.
Provider authentication is a separate setup step; keep credentials in Pi's
supported storage rather than tim project metadata.

Target Linux x86-64 and ARM64, including WSL2 and Arch. Publish and test a minimum
kernel/libc baseline for each artifact. Language servers, compilers, and other
project tools remain separate dependencies; document those separately from the
base editor/agent package.

The inspected TicketBunker checkout already pins Pi 0.84.2 with per-platform
archive checksums in `ticketbunker/runtime/pi-runtime.json`. Its runtime discovery
and bundled-asset checks are useful packaging precedents. The globally installed
Pi package is 0.84.1, so pin and test the chosen release rather than depending on
whatever `pi` happens to resolve to on PATH.

TicketBunker's Pi extension records session and tool activity in its ledger;
`tb run` supplies context and extension configuration. A future TicketBunker
launch path should preserve relevant launch inputs and load the extension in the
same Pi process that tim controls. Ordinary tim sessions start independently of
`tb run`; attaching TicketBunker context must not require adopting a ticket-bound
session lifecycle. Keep ledger writes in the extension and task mutations behind
TicketBunker's supported interface. Ticket links may be many-to-many. Do not
launch an independent agent session just to display TicketBunker activity.

Partial interoperability is implemented: compatible references, read-only legacy
ticket discovery, JSONL history import, and versioned index export. Existing TicketBunker
`coworker.chat` remains ticket-scoped. Preserve its reference field names and
mention forms, but use a versioned adapter for independent Tim session records;
do not inject local records into its private conversation files or database.
Map explicit TicketBunker repository IDs and branch scopes at the adapter
boundary. See `docs/obsidian/Tim/Tim TicketBunker Compatibility.md` for the source
evidence, proposed indexing contract, and required compatibility checks.

The Obsidian vault root is `D:\Apps\TicketBunker`; its `Tim/` folder contains
the tim model notes. Workspace copies are in `docs/obsidian/Tim/`. These describe
the proposed tim boundary, not the results of the separate TicketBunker audit.

Sources inspected: installed Pi 0.84.1 RPC documentation and the local
TicketBunker runtime manifest, runtime discovery module, and Pi extension.
Upstream references: [Pi RPC](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md)
and [Neovim application paths](https://neovim.io/doc/user/starting/#NVIM_APPNAME).

## First working milestone

Implemented: named/default local sessions; isolated launcher and ordinary Neovim
plugin; source selection and unsaved snapshots; local line-comment threads;
Pi RPC streaming/cancellation/recovery; focused/split/file views; source mentions;
automatic Git context; inherited history and index export. Headless Neovim tests
exercise the full editor loop using a deterministic Pi fixture. The installed
Pi 0.84.1 has also passed real RPC startup/state/history checks; authenticated
model generation is not part of the automated suite.

Still pending: bundled runtimes, live TicketBunker database adapter/consumer,
automatic patch application, ranked/semantic retrieval, a recent-project picker,
multiline extension dialogs, and attachment from multiple editors. Existing
source files are edited by the person; Pi editor tools publish data only.

New transcript output follows the latest reply while working in code/input, but
preserves the cursor when reading chat history. Read-only status reports proposals, replies, or
failures; the thread Back control returns to file history. A settled turn with no text reply is an explicit failure; projected
request errors remain visible after Pi persists the user message.
