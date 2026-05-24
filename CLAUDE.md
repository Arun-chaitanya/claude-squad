# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Claude Squad is a bash-based CLI tool that orchestrates multiple Claude Code sessions in side-by-side tmux panes. It implements the [GAN-style harness pattern](https://www.anthropic.com/engineering/harness-design-long-running-apps) — separating code generation from evaluation to overcome Claude's self-praise bias. Agents communicate through a shared JSONL mailbox file and sprint files.

## Commands

```bash
# Install (adds `squad` to PATH via shell rc file)
./install.sh && source ~/.zshrc

# Launch coder + tester (default roles)
squad start

# Launch with a sprint file (coder starts working immediately)
squad start sprints/my-feature.md

# Launch with custom roles (full harness)
squad start --roles planner,coder,tester

# Launch with git worktree isolation per agent
squad start --roles planner,coder,tester --worktrees

# Headless GAN harness (Planner→Generator→Evaluator loop)
squad harness "Build a todo app with real-time sync"

# Other commands
squad stop       # Kill tmux session
squad status     # Show status dashboard
squad watch      # Live-updating dashboard
squad attach     # Jump into tmux session
squad roles      # List available roles
squad init       # Copy sprint template to ./sprints/
squad merge coder # Merge worktree branch back
```

There are no build steps, linters, or tests — this is a pure bash project.

## Architecture

The system has four layers:

1. **CLI (`bin/squad`)** — Entry point. Parses args, validates roles, generates per-role prompt files and launcher scripts into `.squad/`, creates the tmux session, launches Claude Code in each pane with `--append-system-prompt-file` and `--dangerously-skip-permissions`.

2. **Libraries (`lib/`)** — `tmux.sh` manages session creation, pane layout, and send-keys. `mailbox.sh` manages the append-only JSONL mailbox at `.squad/mailbox.jsonl`. `worktree.sh` manages git worktree isolation. `harness.sh` implements the GAN-style Planner→Generator→Evaluator loop. `monitor.sh` provides the status dashboard. `prompt.sh` generates per-role system prompts.

3. **Roles (`roles/*.md`)** — Markdown system prompts injected into each Claude Code session. Define the agent's behavior, workflow, communication protocol, and rules. Roles: planner (spec expansion), coder (implementation), tester (Playwright QA + scoring), reviewer (code review).

4. **Harness (`lib/harness.sh`)** — The GAN-style orchestration loop. Planner expands prompt into spec + rubric. Generator implements sprints. Evaluator tests with Playwright, scores against rubric (4 criteria, 1-10 scale), files bugs. Loop repeats until score threshold (7.0/10) or plateau detected.

### Agent Communication Flow

Agents use two channels:
- **Sprint file** (rich context) — Agents read/write story status (`[CURRENT]` → `[TESTING]` → `[DONE]`), coder notes, and test results.
- **Mailbox** (signals) — Short JSON messages to `.squad/mailbox.jsonl`. The mailbox is append-only JSONL with flock-based locking.

Key design constraint: the coder must NOT send tmux notifications to the tester while it's mid-testing. Instead it queues work by marking stories `[TESTING]` in the sprint file.

### Evaluation Criteria (from the blog)
1. Product depth (threshold: 6/10)
2. Functionality (threshold: 7/10)
3. Visual design (threshold: 5/10)
4. Code quality (threshold: 6/10)

### Runtime Directory

`squad start` creates `.squad/` in the target project containing: `mailbox.jsonl`, `session.json`, per-role `prompt-*.md` and `launch-*.sh` files, sprint specs, feedback files, and score files.

## Adding a New Role

Create `roles/<rolename>.md` following the structure in `coder.md` or `tester.md`. Required sections: job description, sprint file interaction, mailbox communication (with tmux pane indices), workflow steps, and rules. Launch with `squad start --roles <rolename>,coder,tester`. Pane indices are positional (first role = pane 0, second = pane 1, etc.).

## Key Constraints

- Tmux session name is hardcoded to `claude-squad` in `lib/tmux.sh`.
- Pane targeting uses positional indices (`claude-squad:0.N`).
- The mailbox is append-only JSONL with flock-based locking.
- Context resets (fresh `claude -p` calls) are preferred over compaction for the headless harness.
- Git worktrees provide filesystem isolation when `--worktrees` is used.
