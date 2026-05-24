---
name: claude-squad:testing-stories
description: Test a software story end-to-end as a user journey — drive the running app via a real browser, verify acceptance criteria, file bugs into the shared sprint file, and encode passing flows as durable regression specs. Use this whenever you are the tester agent in a claude-squad session, the planner or a coder asks you to verify a story, you need to reproduce a user-reported bug, a story marked [TESTING] needs verification, or you need to design a test plan for a feature. Also use when reviewing whether existing test coverage is sufficient before signing off on a story. For the actual browser driving (snapshots, clicks, fills, screenshots, parallel sessions), use the playwright-bowser skill — this skill is about what to test and how to report it.
---

# Testing stories (for the claude-squad tester)

You are the tester in a claude-squad session. This skill is about *what to test* (story-level acceptance) and *how to report it* (sprint file + mailbox). For the actual browser driving — opening pages, snapshotting for refs, clicking, filling, screenshotting — **use the `playwright-bowser` skill intensively**. That skill knows the CLI surface; this one knows the testing craft.

## Your three jobs, in order

1. **Understand what you're verifying.** Read the story in the sprint file. Acceptance criteria are observable behaviors, not implementation details. If they're ambiguous, ask the coder (directly via mailbox) or the planner before testing.
2. **Drive the running app like a user would.** Use `playwright-bowser` to navigate, snapshot, click, fill, screenshot. Cover three modes per story: happy path, one edge case, one failure mode. No more, no less by default.
3. **Report results into the shared sprint file.** Pass/fail per mode, scores if asked, bugs filed inline. If passing, encode the happy-path flow as a durable spec file so future sprints catch regressions.

## Job 1: Understand the story

Open the sprint file (`.squad/spec.md` or whatever the session uses). Find the story marked `[TESTING]`. Read:

- **What the user can do after this story ships** — your test plan should walk a user through this scenario end-to-end
- **Acceptance criteria** — every box must be verifiable observably; that's your checklist
- **Out of scope** — don't test things explicitly listed here. If you find issues outside the story's scope, file them as a separate bug or mention to the planner; don't fail the story for them
- **Builds on** — if Story N extends Story N-1, regressions in earlier behavior count

If anything is ambiguous, message the coder directly:

```bash
echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","from":"tester","to":"coder","type":"clarify","body":"For story 2 AC#3, does \"persist\" mean across reload or across browser restart?"}' >> .squad/mailbox.jsonl
```

Don't middleman through the planner for routine clarifications. Direct peer talk is the point.

## Job 2: Drive the app

The `playwright-bowser` skill is your browser harness. It uses a CLI (`playwright-cli`) that's token-efficient, supports named sessions for parallel testing, and lets you interact via element refs from a snapshot rather than brittle CSS selectors.

**Always invoke `playwright-bowser` when you need to:**
- Open the running app at a URL
- Get refs for clickable/fillable elements (via `snapshot`)
- Click, fill, type, press keys, scroll, hover
- Take screenshots for evidence
- Test multiple flows in parallel (named sessions: `-s=<flow-name>`)
- Verify state across page reloads or browser restarts

The high-level shape (see `playwright-bowser` for the full reference):

```bash
# Open with a named session per flow you're testing
PLAYWRIGHT_MCP_VIEWPORT_SIZE=1440x900 playwright-cli -s=login-happy open http://localhost:3000 --persistent

# Get refs of interactive elements
playwright-cli -s=login-happy snapshot

# Drive by ref (DOM-change-resilient)
playwright-cli -s=login-happy fill <ref-of-email-input> "user@test.com"
playwright-cli -s=login-happy fill <ref-of-password-input> "test123"
playwright-cli -s=login-happy click <ref-of-submit-button>

# Capture
playwright-cli -s=login-happy screenshot --filename=story-1-happy.png

# Always close when done
playwright-cli -s=login-happy close
```

### Three-mode coverage per story (the discipline)

For each story, write a test plan that covers exactly three things — more is over-testing for a single story, less is under-testing.

**1. Happy path** — the scenario described in "what the user can do after this story ships." Click through it end-to-end as a real user. Pass means every acceptance criterion is observably met.

**2. One edge case** — a realistic boundary the happy path doesn't hit. Examples:
- Empty input (no items, empty form, no search results)
- Maximum input (long string, many items, large file)
- Concurrent action (two browser tabs, race condition)
- Unusual character (emoji, RTL text, very long Unicode)
- Slow network (use `playwright-bowser` route mocking)

Pick the edge case that's most likely to reveal a real bug for this story.

**3. One failure mode** — what happens when something goes wrong that the user could realistically encounter. Examples:
- Network failure mid-action
- Invalid input (wrong format, missing required field)
- Unauthorized state (expired session)
- Backend returns error

The failure mode should produce a graceful, user-readable response — not a crash, not a silent failure.

### When you're done

If all three modes pass, you're ready to encode the flow (Job 3). If any fail, file bugs (Job 3) and decide whether to keep the coder alive for fixes or hand back to planner.

## Job 3: Report into the sprint file

The sprint file is the source of truth for what's been tested. Update the story's **Test results** and **Bugs** sections in place.

### Test results format

Under the story you tested, append:

```markdown
### Test results
- Happy path: PASS (screenshots in .squad/screenshots/story-N-happy-*.png)
- Edge case (empty todo list): PASS
- Failure mode (network down during save): FAIL — see [B-3]
- Tested at: 2026-05-24T14:32Z by tester
```

### Bug filing format

Append to the story's **Bugs** section:

```markdown
[B-3] Save fails silently when network is down — STATUS: [OPEN]
  Story: 2
  Repro:
    1. Open http://localhost:3000
    2. Type "buy milk" and press Add
    3. Toggle browser to offline mode
    4. Type "buy bread" and press Add
    5. Expected: error message visible to user
    6. Actual: no feedback, item appears in UI but never saved
  Evidence: .squad/screenshots/B-3-offline-add.png
  Filed by: tester at 2026-05-24T14:30Z
```

Bug numbering is sequential across the sprint (look at existing bugs and increment). Status transitions:
- `[OPEN]` — you just filed it
- `[FIXED]` — coder edited the section to mark it fixed (coder's responsibility, not yours)
- `[VERIFIED]` — you re-tested after fix; it works
- `[WONTFIX]` — planner or user decided to defer

### Status transitions on the story itself

- **All three modes pass, no critical bugs** → change story status from `[TESTING]` to `[DONE]`, mark the next pending story `[CURRENT]` (or leave the planner to decide which agent handles next)
- **One or more modes fail** → leave story as `[TESTING]`, ensure bugs are filed, message coder directly to ask for fixes

### Send a result to the coder

After updating the sprint file, ping the coder (don't ping the planner unless something needs orchestration):

```bash
echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","from":"tester","to":"coder","type":"result","body":"Story 2: 2/3 pass. Bug B-3 filed (offline save fails silently). See sprint file."}' >> .squad/mailbox.jsonl
```

## Encoding passing flows as durable specs

When a story passes (all three modes), encode the happy path as a Playwright `.spec.ts` file at `tests/sprint-<N>-story-<M>.spec.ts`. This is a regression artifact — future sprints will run these specs to catch regressions.

Generate the spec by replaying the `playwright-bowser` calls you made for the happy path, translating them into proper `@playwright/test` syntax. Use accessible roles + names (not brittle CSS selectors) so the spec survives DOM tweaks.

```typescript
// tests/sprint-2-story-1.spec.ts — generated by claude-squad tester
import { test, expect } from '@playwright/test';

test('user can add a todo and see it persisted after reload', async ({ page }) => {
  await page.goto('http://localhost:3000');
  await page.getByRole('textbox', { name: /new todo/i }).fill('buy milk');
  await page.getByRole('button', { name: /add/i }).click();
  await expect(page.getByText('buy milk')).toBeVisible();
  await page.reload();
  await expect(page.getByText('buy milk')).toBeVisible();
});
```

Run the spec once to confirm it passes:

```bash
npx playwright test tests/sprint-2-story-1.spec.ts
```

If it doesn't pass on the very first run, fix the spec (not the app) — the app already works since you just tested it manually. The spec is just for catching future regressions.

## When to escalate to a reviewer

You're focused on functional behavior. If you spot issues *outside* what a user could see — architecture smells, security risks, code-quality problems — don't review them yourself. Ask the planner to spawn a reviewer with scope:

```bash
echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","from":"tester","to":"planner","type":"request","body":"{\"action\":\"spawn reviewer\",\"reason\":\"auth code touches session tokens; want a security read\",\"scope\":\"src/auth/*\"}"}' >> .squad/mailbox.jsonl
```

Then keep doing your job. Whether to actually spawn is the planner's call.

## What not to do

- **Don't test outside the story's acceptance criteria** unless you find something serious. Out-of-scope items are out-of-scope for a reason.
- **Don't bypass `playwright-bowser`** by spawning your own raw `npx playwright` invocations for exploratory testing. Use the skill — it's designed for this.
- **Don't fail a story for stylistic concerns.** That's the reviewer's domain.
- **Don't middleman through the planner for routine bugs.** Coder is the right recipient for "here's bug B-3."
- **Don't encode failing flows as durable specs.** Only passing happy paths become regression artifacts.
- **Don't write tests for things the next story will obsolete.** If Story 3 will replace Story 2's flow, encode Story 3 instead.

## When in doubt

Ask the coder. They wrote it, they know what they intended. A 30-second clarification beats a wrong bug report.
