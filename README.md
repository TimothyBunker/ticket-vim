# tim

This repository contains the Neovim version of Tim. A later Tim Desktop workspace is being developed locally with a Theia interface; that implementation is not included in this public snapshot.

A small Neovim work editor with a supplementary Pi agent in view. You edit;
the agent answers questions about selected code. Local comments, drafts, and
named sessions work without Pi or TicketBunker.

Requires **Neovim 0.11+**, **Git** for Git context, and **Pi** for agent replies.
Pi must already be authenticated using its normal setup. No Lua installation,
Python backend, plugin manager, or frontend build is required to run Tim.

## Start

```sh
tim -s work             # Create or choose work, and make it the default
tim src/parser.py       # Edit a file with work beside it
tim                     # Open the default session by itself
```

If no default has been selected, Tim asks **Name this session:**. Canceling leaves
your file open. Defaults belong to the current folder or Git worktree; a different
repository has its own default. `tim -s another` changes it. There is no special
“project file”: just open any file you want to edit, using `tim filename` or
Neovim's `:edit filename`.

For a new installation, put the launcher on your PATH (once):

```sh
mkdir -p ~/.local/bin
ln -s /path/to/Bunker/bin/tim ~/.local/bin/tim
```

The launcher resolves its installation through the symlink. It finds `nvim` on
PATH, or a local runtime at `.tools/neovim/bin/nvim`. This workspace includes that
local runtime; other installations need Neovim 0.11+. `~/.local/bin` must be on PATH.

Git context is captured automatically. Optional `tim --branch` selects the latest
session used on the current branch without changing the saved default. It does
not bind a session, require a ticket, or modify Git. Non-Git folders work too.

The launcher uses an isolated `NVIM_APPNAME=tim` configuration. Advanced overrides:
`TIM_NVIM`, `TIM_PI`, and `TIM_DATA_DIR` select executables or local storage.

To load Tim into your existing Neovim instead:

```lua
vim.opt.runtimepath:prepend('/path/to/Bunker')
require('tim').setup({
  pi_command = 'pi',
  -- model = 'provider/model',
  -- startup = true, -- open Tim automatically
  -- mappings = false,
})
```

## Ask for a shell command with tt

`tt` is a small companion for Bash. Type a request at your terminal prompt:

```sh
tt "search for 'egg salad' in lunch menu directory"
```

Press **Enter** to ask Pi. The input becomes a command such as:

```sh
grep -RnF -- 'egg salad' 'lunch menu'
```

The command stays on the prompt. Edit it normally, press **Enter** to execute it,
or **Ctrl-C** to discard it. Ctrl-C also cancels an in-progress request. If Pi fails,
your request remains available to edit and retry. Approved commands enter normal
shell history. Both Emacs and Vim shell editing modes work.

Install the launcher and enable prompt replacement in Bash:

```sh
ln -s /path/to/Bunker/bin/tt ~/.local/bin/tt
# Add this line to ~/.bashrc, then open a new terminal:
eval "$(tt --shell-init bash)"
```

For this checkout alone, `source /path/to/Bunker/shell/tt.bash` enables it for the
current terminal. Integration replaces Bash's Enter bindings and preserves prompt
hooks; remove the initialization line and open a new shell to uninstall it.
Without integration, `tt` simply prints the suggestion. `command tt "…"` also
prints it when integration is enabled, for use in a pipeline or script.

This uses Node (already needed by Pi), your existing Pi login and default model.
`TIM_PI` selects the Pi executable; `TT_MODEL` optionally selects another model.
Each request is independent, with no saved session, tools, extensions, skills,
project settings, or project context files. Pi receives the request and current
directory, and does not inspect files. Shell expansions in an intercepted request
are treated as literal text. No generated command is automatically executed.

Checks: `node --test tests/tt.mjs` and `python3 tests/tt_interaction.py`.

## Work with it

Code stays on the left. One agent panel on the right has **Chat**, **Comments**,
and **Diffs**, with one shared input underneath. Switching views preserves your
input. Tab and indentation default to two spaces, including Python.

| Control | One purpose |
| --- | --- |
| Chat | Read and discuss the work |
| Comments | Inspect findings, their status, and local notes |
| Diffs | Inspect every proposal and its approval state |
| Review, beside the input | Prepare a review of the selected code or whole file |
| Enter in the input | Send the visible message or review instructions to Pi |
| Cancel review | Return the input to chat without erasing its text |
| Cancel, while working | Stop the current agent request |
| Retry, after failure/cancellation | Explicitly send the request again with current context |
| Hide / F4 | Hide or restore the agent panel |

**Ctrl-G** switches between source and input. **Escape** returns to code or
closes an explicit selection picker. **Alt-Enter / Ctrl-J** inserts a newline.
Quitting from the file (`:q`, `:wq`, `ZZ`, or Ctrl-Q) exits Tim and asks about
unsaved files. Hiding the panel does not stop the agent.

Select text or lines with Neovim's normal visual selection. The selection stays
highlighted after Escape, with its target shown under the input. **Clear selection**
returns to whole-file context. **Select lines** in Comments can choose separate
lines. Merely moving the cursor does not attach that line.

Review uses the same input: leave it blank for a default review or type optional
instructions. Enter submits. Nothing runs simply because you selected Review.
The target is always visible, and outdated selections must be cleared or selected
again. The complete current buffer, including unsaved edits, accompanies every
request. Files over 256 KB and prompts over 400 KB are rejected before sending.

Request progress and errors remain visible. New replies follow while you work
in code/input; reading chat preserves your place. A timed-out send is uncertain,
never automatically retried. Check its history before using Retry.

## Comments and diffs

Pi publishes findings and proposals through structured editor tools. Comments
show **open**, **proposal ready**, **applied**, **resolved**, or **outdated**.
**Reply** carries the finding into chat; **Resolve** hides its marker while
preserving the record; **Refresh** prepares a new review against current code.
Refresh requires Enter to run, so it cannot overwrite unsent input or start work
silently. A green **◆** beside a comment opens its proposal in Diffs.

Diffs has a selectable list of proposals and a colored preview. A linked
**Comment** button returns to the finding. Each decision is explicit:

- **Apply** validates every target against the preview and changes buffers only.
- **Reject** dismisses the proposal without editing source.
- **Undo** reverses that application's buffers only if no newer work would be lost.
- **Refresh** prepares a request for an outdated or invalid proposal.

Applied buffers remain unsaved until you save them. Approval, rejection, and
undo records survive reopening the session. Diffs remain inspectable afterward.
Existing text files are supported; file creation/deletion/renaming, binary patches,
and EOF-newline changes remain unsupported and cannot be applied.

**Save note**, in Comments, saves the shared input locally against selected code.
It never asks Pi to respond. Enter always sends to Pi; there is no sticky local
comment mode. Old notes and prose-based findings/proposals remain readable.

## Files and references

Use `@src/parser.py`, `@src/parser.py:42`, or `@[path with spaces.py]:42` to
reference files. Ctrl-X Ctrl-O completes paths in input. Click a citation or use
Enter / `gf` on it to open the file and highlight its location. Historical anchors
relocate only when their captured text matches unambiguously.

Open files appear as tabs sharing the same session. Click tabs or use
Ctrl-PageUp/Ctrl-PageDown; **+ Open file** opens a picker. A tab's **×** closes that
buffer with an unsaved-edit prompt; closing the last file exits Tim. The source
header's **Points**, or `]c` / `[c`, moves through anchored findings.

<details>
<summary>Optional Vim commands</summary>

`:ask question` sends immediately; `:comment note` saves locally immediately.
Both accept line ranges and visual selections. Without text, they focus input.
`:TimSplit` / `:Tim` show split/focused session views. `:TimFile` / `:TimAll`
choose file/full history; `:TimRelated` includes other sessions. `:TimFiles`
chooses a file, `:TimSession name` chooses the default session, `:TimStop` cancels,
and `:TimSaveComment` saves a local note. See `:help tim` for the full list.

</details>

Pi runs in RPC mode with read/search tools plus Tim's bundled
`editor_comment` and `editor_propose_diff` tools. Automatic third-party extension,
skill, and template discovery is disabled. The editor tools publish typed data;
they cannot apply patches, save files, or run shell commands. These tool
restrictions are not an OS filesystem sandbox.

## TicketBunker interoperability

Tim uses compatible source-reference fields and `@` forms, while owning its local
session lifecycle. It can discover branch-matching ticket metadata from existing
legacy `.tb` records and `.ticketbunker.json`; `:TimTicket` explicitly attaches a
matching ticket's summary to the next question. Absence of those files is normal.

```vim
:TimImport /path/to/messages.jsonl
:TimExport /path/to/new-session-index.json
```

Import accepts TicketBunker coworker messages or Pi JSONL history, leaves the
original untouched, and deduplicates repeated imports of the same source records.
Imported messages are historical context: select one and press `a` to attach it
to a new question. Import does not resume or mutate the original agent session.
Export produces a versioned JSON snapshot with source references, captured Git
context, and source-save records. Export refuses to overwrite an existing file.

**No TicketBunker database writes, live synchronization, or existing-app import
consumer are implemented.** Legacy discovery does not cover newer database-only
TicketBunker installations. Their metadata can be added through a future adapter.

## Storage and recovery

Sessions live under `$TIM_DATA_DIR/projects/<id>/sessions/<id>` or Neovim's data
directory under `tim/projects`. Names are labels, never storage paths.
`preferences.json` stores the chosen default session ID.
`state.json` holds drafts, comments, source snapshots, submission metadata,
imported history, and a rebuildable Pi-entry projection. Pi writes its native
`pi.jsonl` history. Tim never rewrites Pi's log.

Metadata replacement is atomic and files are private to the local user. A writer
lock prevents two Tim instances from editing the same session. It does not lock
other applications. A missing response after sending is marked **uncertain**;
Tim does not automatically resend it. Inspect the recovered history first.

## Development

```sh
TIM_NVIM=/path/to/nvim tests/run.sh
TIM_NVIM=/path/to/nvim python3 tests/interaction.py
node tests/editor-tools.mjs
# Optional: protocol-only check against an installed Pi (no model request)
nvim --headless -u NONE -i NONE -l tests/pi-smoke.lua
```

Tests run real headless Neovim with a deterministic Python 3 RPC fixture. They
exercise sessions, Git/worktree metadata, unsaved references, comments, history
filtering, Pi framing, cancellation, crash recovery, imports, buffers and the
launcher. The terminal test covers review, follow-up, stale context, rejection,
cancel/retry, apply/undo, save, and reopening. The Pi smoke test verifies that the
structured editor extension loads without making a model call. Python is a test-only dependency.

Current limits: one active agent turn per editor; full local history is loaded in
memory; inherited history is opt-in; multiline Pi extension dialogs are cancelled
with a notice; language servers and compilers are not bundled. Live
authenticated model access depends on your Pi configuration.
