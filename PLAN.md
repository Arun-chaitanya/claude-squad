# Dynamic, Human-Steerable Multi-Agent Harness — Plan & Execution Sprint

## Context

`claude-squad` today implements Anthropic's GAN harness (planner → coder → tester) but the topology is frozen at boot: panes are created up-front, targeted positionally, agents talk only along a hub-and-spoke path, and they run until the session is killed.

You want a runtime where the planner starts alone, spawns peers on demand, agents talk freely peer-to-peer, the planner is only an arbiter (not a gatekeeper), you can interrupt any pane at any time and your stdin OVERRIDES any pending mailbox instruction, lifecycle is a negotiation between peers, and sprints are vertical-slice stories you can demo after each one.

The end-state is rebuilt on the existing mailbox (which is already routing-flexible) and existing worktree isolation. Headless `squad harness` stays untouched.

---

## End-state architecture (one paragraph)

`squad start` opens a tmux session with only the planner. Pane identity is by role-instance name (e.g. `coder`, `coder-2`), looked up via a small registry backed by tmux `@agent_role` user options on stable `%N` pane ids. New CLI verbs `squad spawn <role>`, `squad kill <role>`, `squad roster`, `squad doctor` make the topology live. The mailbox gains lifecycle event types (`agent_spawned`, `agent_closing`, `agent_closed`, `agent_vanished`, `retiring_in`) but its storage and routing stay identical. Each agent can choose to maintain `.squad/handoff-{name}.md` when killed, and `squad spawn` doesn't auto-inject a resume preamble — the agent that invokes the spawn (usually the planner) decides whether/how to brief the new instance about prior state. Sprints are vertical-slice stories: each one a complete demoable UI flow.

---

## Design intent — read this before changing anything

**The harness provides MECHANISMS only. All POLICY is dynamic and lives in conversation.**

What this means in practice:

- The CLI verbs (`squad spawn`, `squad kill`, `squad doctor`, `squad roster`) are mechanism. They give agents the ability to create, retire, and observe peers. *When* to call them is the agent's judgment in the moment.
- System prompts (`.squad/prompt-<name>.md`) describe mechanism — who you are, where files are, how the mailbox works. They do NOT prescribe workflow, handoff format, conversational ceremony, or behavior rules the model already handles by default.
- When the planner spawns a coder, the planner briefs it via a follow-up message — not via static prompt-file content. The brief is whatever the situation requires. If there's a handoff to resume from, the planner says "read `.squad/handoff-coder.md` and tell me what you're picking up." If it's a fresh task, the planner just states the task.
- `squad spawn` does NOT prepend a "you are resuming" preamble even when a handoff file exists. The file is a *mechanism* (persists across kill/spawn cycles); whoever invokes the spawn decides whether and how to use it.
- `squad start` does NOT send a kick-off prompt to the planner. The first user turn (you typing in the pane) is the brief.
- No "Section 0: HUMAN INTERRUPT IS SOVEREIGN" rules in role files. The model already listens to the most recent stdin in a pane. Don't fight defaults.
- No "Handoff Hygiene" sections enumerating required fields. The planner decides what each handoff should contain based on the situation.
- No "always check `docs/`" directives. The user/planner passes pointers in conversation.

**Future improvements go in skills, not in role prompts.** Patterns like structured-handoff, fatigue-watcher, or sprint-arbitration can be packaged as skills and invoked when needed, but the base prompts stay minimal.

---

## Files touched

| File | Change |
|---|---|
| `lib/registry.sh` | **NEW** — agent registry (mkdir-locked jq edits on `.squad/session.json`) |
| `lib/tmux.sh` | Rewrite — index → pane_id, single-pane boot, spawn/kill APIs |
| `lib/prompt.sh` | Rewrite — drop static pane map, add resume preamble |
| `lib/mailbox.sh` | Extend type catalog; envelope gains `id` / `in_reply_to` / `priority` |
| `lib/monitor.sh` | Rewrite — iterate registry by pane_id |
| `bin/squad` | Rewrite `cmd_start`; add `cmd_spawn`, `cmd_kill`, `cmd_roster`, `cmd_doctor` |
| `roles/planner.md` | Section 0 + interactive workflow + arbiter + spawn discipline |
| `roles/coder.md` | Section 0 + delete obsolete tester-blocking rule + roster lookup + Explore→Plan→Implement→Verify + live handoff |
| `roles/tester.md` | Section 0 + MCP-first hybrid + three-mode coverage + direct Q&A |
| `roles/reviewer.md` | Section 0 + on-demand identity + self-close protocol |
| `templates/sprint.md` | Full rewrite — vertical-slice story schema |
| `PLAN.md` | **NEW** in repo — this plan, mirrored for in-tree visibility |

Untouched: `lib/harness.sh` (headless path), `lib/worktree.sh`, `install.sh`.

---

## Execution sprint — vertical-slice stories

Rule: **after every story the squad is fully usable end-to-end up to the capabilities that story added.** You can manually exercise it and confirm "everything up to here works" before moving on.

---

### Story 1 — `squad start` boots a planner-only session you can chat with

**What ships:** `squad start` (default, no roles flag) opens tmux with a single full-screen pane running the planner. The planner has a fresh system prompt that says "you are interactive with the user; do NOT spawn anyone yet, just talk." No other agents exist. Registry file `.squad/session.json` lists one alive agent: the planner, keyed by pane_id `%N`. The legacy fixed-roster behavior moves behind `squad start --static <roles>` so the old flow isn't broken.

**Demo after this story:**
- `cd` into a scratch repo, run `squad start`.
- `squad attach` → see one big planner pane.
- Type "let's plan a todo app" into the planner. It responds, asks questions, doesn't try to spawn anything.
- `squad status` shows one alive agent.
- `squad stop` cleans up.

**Out of scope this story:** spawning new agents, killing agents, mailbox protocol changes, role section 0. Just boot + chat.

---

### Story 2 — `squad spawn <role>` brings a coder pane to life from inside or outside the planner

**What ships:** New `squad spawn coder` CLI verb. Creates a new tmux pane (split + tiled), assigns `@agent_role=coder` + `@agent_instance=1`, generates the coder's prompt+launcher with the rewritten `lib/prompt.sh` (no static pane map; just role name and a "look up live roster on demand" instruction), launches Claude inside, and registers the new agent in `.squad/session.json`. A `mailbox agent_spawned` broadcast lands. Spawning again creates `coder-2`, `coder-3`, etc., each on its own pane and (if `--worktrees`) its own worktree. Concurrent spawns are guarded by a `.squad/spawn.lock`.

**Demo after this story:**
- `squad start`, attach, chat with planner.
- From the host shell (or by shelling out from inside planner's pane): `squad spawn coder` → new pane appears, runs Claude Code, has its own prompt.
- `squad spawn coder` again → `coder-2` appears in a third pane.
- `squad roster` (new tiny CLI verb) → prints both alive coders + planner.
- Type into the coder's pane: "what's your name?" → it answers "coder" or "coder-2" based on registry.
- `cat .squad/session.json | jq '.agents'` shows three entries, all `status:"alive"`.

**Out of scope this story:** killing, lifecycle mailbox messages, role section 0 / human-interrupt rules, planner auto-spawning. Spawn is manual from the shell for now.

---

### Story 3 — `squad kill <role>` gracefully tears down a pane, preserving handoff

**What ships:** New `squad kill coder-2 [--grace-seconds N] [--hard]` CLI verb. Soft path: sends `mailbox agent_closing` broadcast, waits N seconds (default 10), then `tmux kill-pane`. Coder's role prompt is updated (small change) so it maintains `.squad/handoff-coder.md` after every meaningful action — that's what makes the soft grace window safe. Registry flips the entry to `status:"killed"` with `killed_at` and `handoff` path. Refuses if killing would leave zero panes; tells you to use `squad stop` instead. New `squad doctor` reconciles registry against `tmux list-panes` and flips orphans to `status:"vanished"`.

**Demo after this story:**
- `squad start`, `squad spawn coder`, `squad spawn coder` (now `coder-2` alive).
- Type some real work into `coder-2` — let it write a couple of files.
- `squad kill coder-2` → mailbox shows `agent_closing`, 10s later the pane disappears.
- `cat .squad/handoff-coder-2.md` → contains current task / decisions / next step.
- `squad roster` shows planner + coder alive; `coder-2` is killed.
- Manually `tmux kill-pane` on coder, then `squad doctor` → registry flips coder to `vanished`.
- Try `squad kill planner` → refused with "use squad stop."

**Out of scope this story:** respawn-with-resume-preamble, planner-driven kill, peer-arbitrated kill via mailbox. Kill is manual from the shell.

---

### Story 4 — Respawn resurrects the Claude conversation itself

**What ships:** Pure mechanism. No prompt-content changes.

- **Claude session id persists across kill/spawn.** Every agent is launched with a stable UUID via `claude --session-id <uuid>` (assigned at spawn time and stored in the registry). On graceful kill, the id remains in the registry under the killed entry. When the same name is respawned, the launcher uses `claude --resume <uuid>` instead — the new pane comes back as *the same Claude conversation*, with full history, todos, scratchpad intact. This is qualitatively stronger than handoff-file resumption.
- **Instance numbers are resurrected, not climbed.** When `coder` is killed and you spawn `coder` again, it comes back as `coder` (instance 1), not `coder-2`. The killed entry is removed and the new alive entry takes its place. Only when you want a *parallel* second instance alongside the alive one does the number climb.
- **Worktree is reused** if one exists from a prior life — uncommitted work is preserved.
- **`--fresh` discards both** the prior Claude session id (generates a new UUID) and the handoff file (renamed to `.archived-<ts>.md`).
- **No auto-injected resume preamble.** The system prompt does NOT tell the resurrected agent "you are resuming — read the handoff file." The planner briefs it via a follow-up message if a brief is needed. Mechanism only; policy stays in conversation.

**Demo after this story:**
- `squad start --worktrees`, `squad spawn coder`, do some work.
- `squad kill coder` → handoff file preserved (if the agent wrote one), worktree intact, registry remembers the Claude session id.
- `squad spawn coder` → CLI prints "Resurrected coder — Claude conversation resumed." The launcher now uses `--resume <uuid>`. New pane has the full prior conversation visible.
- `squad spawn coder --fresh` → CLI assigns a new UUID, archives handoff, launcher uses `--session-id` (fresh conversation).

**Out of scope this story:** any role-prompt changes, any auto-brief injection.

---

### Story 5 — Free-flowing peer collaboration + recycling mechanism

**What ships:** Mechanism only. No policy, no role-prompt changes (per the Design intent at the top of this doc).

**(A) Peer-to-peer mailbox.** The mailbox already routes any `from → to`. This story just adds a type-catalog comment in `lib/mailbox.sh` documenting the conventions agents can use: `notification`, `request`, `ack`/`decline`, `result`, `clarify`, `block`, `status_update`, `redirect`, plus system lifecycle events (`agent_spawned`, `agent_closing`, `agent_closed`, `agent_vanished`, `recycling`). Nothing is enforced — agents choose what fits the moment.

**(B) Signal source for the planner.** `squad usage <name>` reads the agent's Claude session log (`~/.claude/projects/<encoded-repo-path>/<session_id>.jsonl`) and prints a JSON object:

```json
{
  "name": "coder",
  "status": "alive",
  "claude_session_id": "...",
  "alive_seconds": 1830,
  "tokens_in": 4123, "tokens_out": 8912,
  "tokens_cache_read": 280000, "tokens_cache_create": 35000,
  "tokens_total": 328035,
  "mailbox_sent": 14, "mailbox_received": 22
}
```

The harness does not interpret these numbers. The planner reads them whenever it wants (mid-cycle, after a story passes, on user prompt) and decides whether to recycle. Heuristics for "context heavy" or "semantic boundary" live entirely in the planner's conversation with you — not in any role file.

**(C) Recycle convenience verb.** `squad recycle <name> [--reason "..."] [--grace-seconds N] [--fresh]` does `kill + spawn` in one call:
- Default: preserves the Claude session id (`--resume`) and worktree — the planner uses this when it just wants a state checkpoint, not a context wipe.
- `--fresh`: assigns a new Claude session id and archives the handoff — used when the planner judges the next task is unrelated to what the agent has been doing.
- Broadcasts `recycling` mailbox event with `reason` so peers see why.

**No role file changes.** The planner doesn't need a "Fatigue Watcher" section telling it how to interpret usage numbers — it discovers `squad usage` via `squad help` or because you tell it, and decides per-situation. Future improvement: package recycling heuristics as a skill the planner can invoke.

**Demo after this story:**
- `squad start`, `squad spawn coder`, `squad spawn tester`.
- Have coder and tester exchange a few messages (`squad_mailbox_send` from the shell or just type into the panes asking each to talk).
- `squad usage coder` → JSON with token counts, time alive, mailbox sent/received.
- `squad recycle coder --reason "test"` → graceful kill + same-session respawn; `claude_session_id` unchanged.
- `squad recycle coder --reason "next task is unrelated" --fresh` → new session id, archived handoff.
- `jq` the mailbox to see the `recycling` events with reasons attached.

**Out of scope this story:** vertical-slice sprint template (Story 6), MCP Playwright (Story 7), reviewer (Story 8).

---

### Story 6 — Vertical-slice sprint template + `planning-sprints` skill

**What ships:**

- **`templates/sprint.md`** fully rewritten to the vertical-slice schema. Each story has: title (user-observable behavior), "what the user can do after this story ships" paragraph, acceptance criteria (observable, not implementation), out-of-scope list, builds-on note, inline Coder notes, inline Test results, inline Bugs section. Status enum `[PENDING|CURRENT|TESTING|DONE|BLOCKED|USER_OVERRIDE]`. The Bugs section format lets any agent (especially the tester) file bugs directly into the sprint file as work progresses.
- **`skills/planning-sprints/SKILL.md`** — the planner's "how to do the work" skill. Covers: interactive dialogue with the user, vertical-slice story shape (with worked good/bad examples), choosing which agent to wake first (coder for features, tester for bugs), briefing them well, revising mid-flight with `[REVISED]` markers, recycling agents whose context is heavy or whose next task is semantically unrelated. Frontmatter description is "pushy" per Anthropic's skill-writing guidance so the skill auto-triggers when relevant.
- **`roles/planner.md` shrinks to ~25 lines.** Just identity ("you are the planner, singleton, user's primary collaborator"), mechanism pointers (sprint file, mailbox, roster, spawn/kill/recycle/usage CLIs), and a note pointing at the `planning-sprints` skill. All workflow knowledge moved into the skill.
- **`install.sh`** symlinks `skills/*/` directories into `~/.claude/skills/` so spawned agents discover them automatically.

**Demo after this story:**
- `bash install.sh` once → confirms `planning-sprints` shows up at `~/.claude/skills/planning-sprints`.
- `squad start` in a scratch repo.
- Tell planner: "I want to build a minimal kanban board." It should invoke the `planning-sprints` skill (you'll see it propose Story 1 conversationally, not write the spec file yet).
- Push back on Story 1 ("start with two columns visible"), planner revises.
- Say "looks good" through ~3 stories, then "go" → planner writes `.squad/spec.md` and `squad spawn coder`s.
- Type into planner pane: "actually make the columns horizontal." Planner updates the affected story with `[REVISED <date>]` markers and notifies the coder.
- Recycle test: ask planner to `squad recycle coder --reason "test"` and confirm same Claude session resumes (from Story 4 mechanism).

**Out of scope this story:** tester MCP work (Story 7), coder skill (Story 8), reviewer (deferred).

---

### Story 7 — `testing-stories` skill that leans on `playwright-bowser`

**What ships:**

- **`skills/testing-stories/SKILL.md`** — the tester's craft. Covers: reading acceptance criteria from the sprint file, three-mode coverage discipline (happy + edge + failure per story, no more no less), filing bugs inline into the sprint file's per-story Bugs section, encoding passing flows as durable `tests/sprint-N-story-M.spec.ts` regression artifacts, escalating to a reviewer for out-of-scope quality concerns. Pushy frontmatter so it triggers when relevant.
- **Delegates browser driving to `playwright-bowser`.** Instead of teaching the tester `npx playwright` or raw MCP calls, the skill points at the pre-existing `playwright-bowser` skill, which already provides token-efficient CLI access, named parallel sessions, ref-based interaction (DOM-change-resilient), and proper cleanup. Two skills compose: `testing-stories` knows *what* and *how to report*; `playwright-bowser` knows *how to drive a browser*.
- **`roles/tester.md` shrinks to ~25 lines.** Identity + mechanism pointers + a note pointing at both skills. The old GAN-rubric scoring + raw Playwright CLI sections are removed.
- **`install.sh`** already symlinks all `skills/*/` so `testing-stories` is picked up automatically alongside `planning-sprints`.

**Demo after this story:**
- Continue Story 6's kanban demo: planner has spawned coder, coder has marked Story 1 `[TESTING]`.
- Planner spawns tester (or coder asks for tester directly).
- Tester triggers `testing-stories`, reads Story 1, walks through happy + edge + failure modes using `playwright-bowser` (snapshot → ref → click → fill → screenshot).
- Tester appends test results + any bugs inline under Story 1 in the sprint file.
- If passing: tester generates `tests/sprint-1-story-1.spec.ts` and runs `npx playwright test` to confirm it's green.
- Tester messages the coder directly with a `result` mailbox event — no planner middleman.

**Out of scope this story:** the coder skill (Story 8); reviewer (deferred).

---

### Story 8 — `coding-stories` skill

**What ships:**

- **`skills/coding-stories/SKILL.md`** — the coder's craft. Covers: understanding the story before writing (read sprint file + planner pointers + CLAUDE.md + relevant code), writing real code (no stubs, no placeholders, no scope sprawl), self-reviewing the diff before handing off, clean commits, handing off directly to the tester via mailbox. Also covers handling user redirects mid-flight (small ones the coder updates the sprint file for with `[REVISED]` markers; bigger ones go to the planner via `redirect` mailbox), fixing bugs filed by the tester, and resuming cleanly from a handoff file after recycle. Pushy frontmatter description so the skill triggers when the coder picks up work.
- **No internal loop.** The skill explicitly states the coder is not a loop. It finishes its piece (one story or one bug fix), hands off, stops. Whether work bounces back to the same coder or to a fresh one is the planner's decision, made outside the coder per situation.
- **`roles/coder.md` shrinks to ~25 lines.** Identity ("you implement one piece of work at a time, you're not the orchestrator"), mechanism pointers (sprint file, mailbox, handoff file), and a note pointing at the `coding-stories` skill. The old GAN context-reset protocol and the obsolete "don't tmux-notify the tester mid-test" rule are gone.
- **`install.sh`** symlinks `coding-stories` automatically alongside the other two; verified live in the skill registry.

**Reviewer left as-is for now.** The reviewer role is spawned on-demand and the planner briefs it dynamically per Story 5's free-peer-collab model. A dedicated `reviewing-diffs` skill can come later when a clear pattern emerges — that matches the "future improvements go in skills" principle in the Design Intent section. Reviewer role file stays in the old shape until then.

**Demo after this story:**
- Continue Stories 6+7's kanban demo: planner has spawned coder + tester. Coder triggers `coding-stories` on receiving Story 1's brief, implements, self-reviews, hands to tester.
- Tester finds a bug, files it inline in the sprint file's Bugs section, messages coder.
- Coder reads the bug, fixes, marks `[FIXED]`, messages tester back.
- Mid-implementation: type into coder's pane "actually use Zustand, not Redux." Coder pivots without ceremony, updates Story 1's coder notes with the change.
- Bigger redirect: type "we don't need password login at all — magic links only." Coder sends `redirect` to planner; planner updates affected stories in `.squad/spec.md` with `[REVISED]` markers.

**Out of scope this story:** reviewer skill (deferred — invoke on-demand for now); fluent prompts ("how to add a skill" type docs) for future skill authors.

---

## Verification at full completion (after Story 8)

End-to-end demo on a fresh scratch repo:
1. `squad start` → planner-only pane appears.
2. Plan a real feature interactively (e.g., "build a Pomodoro timer web app") through ~4 stories.
3. Say "go" → planner spawns coder. Coder implements Story 1, requests tester, tester verifies (MCP + writes `.spec.ts`), story passes.
4. Mid-Story-2 you interrupt coder via stdin to change direction; verify pivot and `redirect` mailbox message.
5. Tester finds a bug in Story 3, files it, both `request_keep_alive coder` and `request_close tester` arrive within 5s; planner arbitrates within 30s; the losing party gets a clean `arbitrate` decision.
6. Tester requests reviewer for the auth code; reviewer spawns on demand, posts findings, self-closes.
7. After Story 4 passes, kill coder gracefully — handoff preserved. Respawn coder — resume preamble fires, agent picks up cleanly.
8. `npx playwright test` runs all generated spec files green.
9. Throughout: `shellcheck --severity=error bin/squad lib/*.sh` is clean, headless `squad harness` still works in a separate sandbox without touching tmux.

---

## Risks tracked, not blocking

- **Grace window too short on slow models** — make `--grace-seconds` configurable per-role if 10s misbehaves.
- **Mailbox JSONL grows unbounded** — add rotation policy later, not in v1.
- **Planner singleton enforcement** — `cmd_spawn planner` should refuse explicitly.
- **Worktree dirty state on resume** — resume preamble must tell coder to `git status` first and decide stash vs keep.

---

## Deferred improvements (queued)

- **Click-to-focus panes** — tmux ignores mouse clicks by default; you have to use `Ctrl+B + arrow` to switch panes. Adding `tmux set-option -t claude-squad mouse on` right after `new-session` (in `lib/tmux.sh`'s `squad_tmux_create_single_pane`) scopes mouse mode to the squad session only, so you can click panes to make them active without overriding your global tmux preferences. Side benefits: scroll-wheel works, drag-to-resize pane borders works. Side effect to know: selecting text with the mouse goes through tmux's copy mode rather than the terminal's native selection.
