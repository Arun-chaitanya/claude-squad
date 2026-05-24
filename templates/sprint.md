# Sprint

> This is the shared source of truth. The planner drafts it, the coder reads
> stories from it and adds notes, the tester writes results and files bugs
> into it. Any agent (and you) can read or write any section.
>
> Launch with: `squad start path/to/this/file.md`

## What we're building

[1-2 sentences. The planner fills this in after talking with the user. It
should describe the user-observable outcome of the whole sprint — not the
implementation.]

## Constraints / pointers from the user

[Anything specific the user mentioned: files to read, libraries to use or
avoid, conventions to follow, deadlines, prior decisions. The planner
captures verbatim quotes here when ambiguity matters.]

---

## Story 1: [Title — phrase as user-observable behavior]

Status: [CURRENT]

### What the user can do after this story ships
[One paragraph. A scenario someone could click through end-to-end. If you
can't describe it as a user flow, the story is too small or too implementation-shaped.]

### Acceptance criteria
- [ ] Criterion 1 (observable, not implementation)
- [ ] Criterion 2
- [ ] Criterion 3

### Out of scope for this story
- Anything intentionally not included (the planner names these explicitly
  so the coder doesn't sprawl)

### Builds on
[n/a — entry point | Story N, extends Y]

### Coder notes
<!-- The coder appends here as work progresses. Decisions made, libraries
chosen, files touched, anything a future coder (or the tester) needs to know. -->

### Test results
<!-- The tester appends here. -->
- Happy path: [PASS | FAIL]
- Edge case ([what]): [PASS | FAIL]
- Failure mode ([what]): [PASS | FAIL]

### Bugs
<!-- Filed by the tester during testing. Any agent can update status. -->
<!-- Format:
[B-1] Title — STATUS: [OPEN|FIXED|VERIFIED|WONTFIX]
  Repro: steps
  Filed by: <name> at <ts>
  Fixed by: <name> at <ts>
-->

---

## Story 2: [Title]

Status: [PENDING]

### What the user can do after this story ships
### Acceptance criteria
- [ ]
### Out of scope for this story
### Builds on
[Story 1, extends Y by adding Z]
### Coder notes
### Test results
### Bugs

---

<!--
Status enum:
  [PENDING]       not started
  [CURRENT]       coder working on it
  [TESTING]       handed off to tester
  [DONE]          tester verified, story complete
  [BLOCKED]       waiting on something external — agent notes why inline
  [USER_OVERRIDE] user redirected mid-flight; see [REVISED] markers in body

When a story is revised mid-flight (by the user or per peer feedback), edit
the affected sections in place and append a [REVISED <ts>] marker with a
one-line note on what changed and why. Don't delete the prior version —
strikethrough or quote it so history is visible.
-->
