# Dynamic, Human-Steerable Multi-Agent Harness — Plan & Execution Sprint

## Context

`claude-squad` today implements Anthropic's GAN harness (planner → coder → tester) but the topology is frozen at boot: panes are created up-front, targeted positionally, agents talk only along a hub-and-spoke path, and they run until the session is killed.

You want a runtime where the planner starts alone, spawns peers on demand, agents talk freely peer-to-peer, the planner is only an arbiter (not a gatekeeper), you can interrupt any pane at any time and your stdin OVERRIDES any pending mailbox instruction, lifecycle is a negotiation between peers, and sprints are vertical-slice stories you can demo after each one.

The end-state is rebuilt on the existing mailbox (which is already routing-flexible) and existing worktree isolation. Headless `squad harness` stays untouched.

---

## End-state architecture (one paragraph)

`squad start` opens a tmux session with only the planner. Pane identity is by role-instance name (e.g. `coder`, `coder-2`), looked up via a small registry backed by tmux `@agent_role` user options on stable `%N` pane ids. New CLI verbs `squad spawn <role>`, `squad kill <role>`, `squad roster`, `squad doctor` make the topology live. The mailbox gains lifecycle message types (`request_spawn`, `request_close`, `request_keep_alive`, `handoff_ready`, `arbitrate`, `redirect`) but its storage and routing stay identical. Each role's system prompt is rewritten so its top section is "Human Interrupt Is Sovereign" — stdin from you always wins over any mailbox instruction. Each agent continuously maintains `.squad/handoff-{name}.md` so kill-at-any-moment is safe. Sprints become vertical-slice stories: each one a complete demoable UI flow, each subsequent story extending the prior.

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

### Story 4 — Respawning a killed agent picks up where it left off

**What ships:** `squad spawn coder` now checks for `.squad/handoff-coder.md` and, if present, prepends a "Resumption Context — read this file first" preamble to the generated prompt. If a worktree already exists for that role+session, reuse it. Instance numbers prefer reuse (killed `coder-2` resumes as `coder-2`, not `coder-3`). New `--fresh` flag on spawn renames the handoff to `.archived` if you want a clean start.

**Demo after this story:**
- Run Story 3's demo so `coder-2` has a populated handoff and worktree with uncommitted work.
- `squad spawn coder` (or `squad spawn coder --instance 2`) → new pane comes up, agent's first action is reading the handoff, it summarizes "I was working on X, next step is Y."
- It picks up the same worktree (verify with `git -C ...worktrees/.../coder-2 status`).
- `squad spawn coder --fresh` → handoff renamed `.archived-<ts>.md`, new agent starts clean.

**Out of scope this story:** anything in the mailbox or role-prompt protocol layer beyond the resume preamble.

---

### Story 5 — Human-interrupt protocol: typing in any pane immediately steers that agent

**What ships:** Section 0 ("HUMAN INTERRUPT IS SOVEREIGN") added to the top of `roles/planner.md`, `roles/coder.md`, `roles/tester.md`, `roles/reviewer.md`. Defines: pause, update handoff, acknowledge in one sentence, ask at most one clarifying question, send `redirect` mailbox to planner, follow new direction. The precedence ladder (HUMAN_STDIN > AGENT_JUDGMENT > MAILBOX `arbitrate` > MAILBOX `request` > MAILBOX `notification`) is stated explicitly. The mailbox gains a `redirect` type so the coder can echo the human override back to planner.

**Demo after this story:**
- `squad start`, `squad spawn coder`, ask planner via mailbox to tell coder "build feature X using Redux."
- While coder is mid-implementation, switch to coder's pane and type "stop — use Zustand instead, not Redux."
- Verify within ~10s: coder acknowledges in one sentence, `.squad/handoff-coder.md` updates to reflect the pivot, a `redirect` message lands in mailbox from coder→planner, coder begins the new direction.
- Type "continue what you were doing" → coder explicitly resumes the prior task (only when you say so).

**Out of scope this story:** automated arbitration of competing peer requests, named-instance spawning by the planner. Just the interrupt behavior.

---

### Story 6 — Free-flowing peer collaboration with planner-driven recycling

**What ships:** Two things working together.

**(A) Peer-to-peer mailbox.** Mailbox type catalog extended (`notification`, `request`, `ack`, `decline`, `result`, `clarify`, `block`, `status_update`, `redirect`, `agent_spawned`, `agent_closing`, `agent_closed`, `agent_vanished`, plus a new `retiring_in <Ns>` event for the recycle flow below). Envelope gains `id` / `in_reply_to` / `priority`. Coder and tester talk to each other directly via mailbox — no planner gatekeeping. Coder's obsolete "do NOT send tmux notifications to tester while mid-testing" rule is deleted; async mailbox replaces it.

**(B) Planner as fatigue watcher.** Agents do NOT decide their own lifecycle. They just work. The planner is the only watcher and makes recycle decisions based on a combination of signals:

| Signal | Source | Trigger |
|---|---|---|
| Tokens consumed by this instance | `~/.claude/projects/.../*.jsonl` session log (find by spawned_at) | ≥ ~150k = danger zone; planner should retire before next task |
| Wall time alive | registry `spawned_at` | very long-running instances get a periodic "still healthy?" check |
| Semantic boundary | sprint file status changes + planner judgment | story `[DONE]` + next story is meaningfully different → fresh instance even if well under budget; same applies when an unrelated bug arrives |
| Mailbox volume from/to agent | `mailbox.jsonl` count | proxy for "how much has this agent been juggling" |

Planner reads these on each cycle and decides whether to recycle. Recycle = `squad kill <name>` (graceful — agent gets `retiring_in 30s`, writes handoff) then `squad spawn <role>` (new instance reads handoff and picks up the next task). Story 4's resume preamble already covers the pickup side.

**Critical rule (encoded in planner.md):** Even with a half-empty token budget, when the *next* task is meaningfully unrelated to what the current agent has been doing (new bug type, new story building on different surfaces, new testing dimension), the planner spawns a fresh instance. Context boundaries are semantic, not just numeric.

**Demo after this story:**
- `squad start`, plan a 2-story sprint, say "go."
- Planner spawns coder. Coder implements Story 1.1, talks directly to tester via mailbox. Tester verifies, posts `result`. Story 1.1 marked `[DONE]`.
- Planner sees Story 1.1 done + Story 1.2 is queued. Decides 1.2 deserves a fresh coder (semantic boundary). Sends `retiring_in 30s` to coder, runs `squad kill coder`, then `squad spawn coder` for 1.2.
- New coder picks up from handoff, implements 1.2, also talks to the same tester directly.
- During 1.2, push the coder hard (force it to use ~140k tokens). On next cycle, planner sees the budget signal and proactively recycles it after current work flushes.
- Inspect: `cat .squad/mailbox.jsonl | jq` shows the free-flowing peer messages + the planner's retiring/spawn events with rationale in the body.

**Out of scope this story:** vertical-slice sprint template (Story 7), MCP Playwright (Story 8), reviewer (Story 9).

---

### Story 7 — Vertical-slice sprint template + interactive planner workflow

**What ships:** `templates/sprint.md` fully rewritten to the vertical-slice schema (Title, User-observable outcome, Acceptance criteria, Out of scope, Builds on, inline Coder notes / Test results, status `[PENDING|CURRENT|TESTING|DONE|BLOCKED|USER_OVERRIDE]`). `roles/planner.md` workflow rewritten: interactive-first dialogue with you to refine stories one at a time, then write `.squad/spec.md` only when you say "looks good," never auto-spawn (wait for "go"/"start"/"spawn"), mid-flight revision updates `.squad/spec.md` in place with `[REVISED]` markers. `roles/coder.md` workflow rewritten to Explore → Plan → Implement → Verify with a `notification` broadcast at the Plan phase so peers see intent.

**Demo after this story:**
- `squad start`, ask planner to plan a "minimal kanban board."
- Planner proposes Story 1: "user sees an empty board with a single Add Card button." You push back: "actually start with two columns visible." Planner revises and re-proposes.
- Iterate until you're happy across ~3 stories, then "looks good" → spec written.
- "go" → planner spawns coder, hands off Story 1 (deliverable behavior + acceptance + out-of-scope, NOT filenames or libraries).
- Coder explores, broadcasts plan, implements, marks `[TESTING]`.
- Mid-implementation you change your mind: "actually make the columns horizontal not vertical." Planner sends `redirect` to coder, updates `.squad/spec.md` with `[REVISED]`.

**Out of scope this story:** tester MCP changes, reviewer.

---

### Story 8 — Tester uses MCP Playwright (hybrid: agentic exploration + durable spec files)

**What ships:** `roles/tester.md` workflow rewritten. The old raw-Playwright-CLI section is deleted. New protocol: navigate via `mcp__playwright__browser_navigate`, snapshot via `browser_snapshot` to get semantic refs, drive via `browser_click` / `browser_fill_form` / `browser_type` on refs (DOM-change-resilient), screenshot at each verification point. For each story: happy path + one edge case + one failure mode (no more, no less). For passing flows, encode as a durable `tests/sprint-{N}-story-{M}.spec.ts` regression artifact. Tester can `clarify` directly to coder (no planner middleman). Tester can `request_spawn reviewer` if it sees architecture/security issues outside its scope.

**Demo after this story:**
- Run Story 7's demo through the full kanban Story 1 + Story 2 lifecycle.
- Watch tester: snapshots the running app, drives clicks on refs, takes screenshots, scores against the acceptance criteria from the sprint file.
- After a passing story, check that `tests/sprint-1-story-1.spec.ts` exists and `npx playwright test` runs it green.
- Force a failure (change a button's accessible name) and rerun → tester still drives via ref-by-name and reports a clear bug with screenshot evidence.

**Out of scope this story:** reviewer behavior changes.

---

### Story 9 — Reviewer role: on-demand spawn, self-close protocol

**What ships:** `roles/reviewer.md` updated. Reviewer is no longer in the default roster; it only exists because some peer sent `request_spawn reviewer` to the planner. Reviewer reads the originating request's body to learn scope, reviews the diff, delivers findings as a `result` message, then either `request_close self` (no follow-up needed) or `request_keep_alive coder` (critical fixes needed). Section 0 + handoff discipline as in other roles.

**Demo after this story:**
- Run Story 8's demo. After a story passes tester, ask tester (via direct prompt) to escalate: "the auth code feels brittle, ask for a reviewer."
- Tester sends `request_spawn reviewer` with scope (file paths from coder's notes).
- Reviewer spawns, reads scope from the request body, posts findings to mailbox as `result`.
- Reviewer self-closes via `request_close self`; planner arbitrates and acks; reviewer's pane disappears.
- If critical issues found, reviewer instead sends `request_keep_alive coder` and coder stays alive to fix.

**Out of scope this story:** nothing — this is the last story.

---

## Verification at full completion (after Story 9)

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
