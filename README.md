# Claude Squad

A bash CLI that orchestrates multiple Claude Code agents in parallel tmux panes, implementing the [GAN-style harness pattern](https://www.anthropic.com/engineering/harness-design-long-running-apps) from Anthropic's engineering blog.

**Key insight**: Separate the agent that *produces* code (Generator) from the agent that *evaluates* it (Evaluator), because Claude consistently over-praises its own output.

## Architecture

```
┌─────────────────────────────────────────────────┐
│                  squad CLI                       │
│  Parses args, generates prompts, manages tmux    │
└────────┬────────────┬────────────┬──────────────┘
         │            │            │
    ┌────▼────┐  ┌────▼────┐  ┌───▼─────┐
    │ Planner │  │  Coder  │  │ Tester  │
    │ (spec)  │  │ (build) │  │ (eval)  │
    │ Pane 0  │  │ Pane 1  │  │ Pane 2  │
    └────┬────┘  └────┬────┘  └────┬────┘
         │            │            │
         └────────────┼────────────┘
                      │
              .squad/mailbox.jsonl
              .squad/spec.md
              .squad/feedback-*.md
```

## Install

```bash
git clone <this-repo>
cd claude-squad
./install.sh && source ~/.zshrc
```

**Requirements**: tmux, claude (Claude Code CLI), jq, git
**Optional**: Playwright (for tester role)

## Usage

### Interactive Mode (tmux panes)

```bash
# Basic: coder + tester
cd /your/project
squad start

# With sprint file
squad start sprints/my-feature.md

# Full harness: planner + coder + tester
squad start --roles planner,coder,tester

# With git worktree isolation per agent
squad start --roles planner,coder,tester --worktrees

# Monitor
squad status        # dashboard
squad watch         # live refresh
squad attach        # jump into tmux
squad stop          # kill everything
```

### Headless Mode (GAN harness loop)

```bash
# Planner → Generator → Evaluator loop with scoring + plateau detection
squad harness "Build a real-time collaborative todo app with websockets"
```

This runs the full Planner→Generator→Evaluator cycle from the blog post:
1. **Planner** expands prompt into spec + evaluation rubric
2. **Generator** implements sprint by sprint
3. **Evaluator** tests with Playwright, scores against rubric (1-10)
4. Loop repeats until score >= 7.0/10 or plateau detected

### Other Commands

```bash
squad roles         # list available roles
squad init          # copy sprint template to ./sprints/
squad merge coder   # merge a worktree branch back
```

## Roles

| Role | Alias | Job |
|------|-------|-----|
| `planner` | Planner | Expands brief prompt into full spec with sprints |
| `coder` | Generator | Implements code sprint by sprint |
| `tester` | Evaluator | Tests with Playwright, scores against rubric, files bugs |
| `reviewer` | Reviewer | Pure code review — security, architecture, correctness |

## How It Works

### Sprint Contracts
Before each sprint, the spec defines deliverables and success criteria. The evaluator tests against these criteria — not vibes.

### File-Based Communication
Agents communicate through:
- **Sprint file** (`.squad/spec.md`) — rich context, status transitions
- **Mailbox** (`.squad/mailbox.jsonl`) — short JSONL signals
- **Feedback files** (`.squad/feedback-sprint-N.md`) — detailed evaluation results

### Evaluation Criteria (from the blog)
1. **Product depth** — beyond surface-level? (threshold: 6/10)
2. **Functionality** — does everything work? (threshold: 7/10)
3. **Visual design** — cohesive and polished? (threshold: 5/10)
4. **Code quality** — clean and maintainable? (threshold: 6/10)

If ANY criterion falls below its threshold, the sprint fails.

### Context Resets > Compaction
The blog found that context resets (fresh agent with structured handoff) work better than compaction (summarizing in-place). Each headless harness iteration uses `claude -p` with a fresh context window.

### Git Worktree Isolation
With `--worktrees`, each agent gets its own copy of the repo via `git worktree`. No filesystem conflicts during parallel work.

## Design Principles

From the blog:
- **"Find the simplest solution possible"** — complexity only when proven necessary
- **"Every component encodes an assumption"** — test what the model can't do alone
- **"The space of interesting harness combinations doesn't shrink"** — as models improve, the frontier moves

## Project Structure

```
claude-squad/
├── bin/squad           # CLI entry point
├── lib/
│   ├── tmux.sh         # tmux session management
│   ├── mailbox.sh      # JSONL mailbox for inter-agent comms
│   ├── worktree.sh     # git worktree isolation
│   ├── harness.sh      # GAN-style harness orchestration
│   ├── monitor.sh      # status dashboard
│   └── prompt.sh       # per-role prompt generation
├── roles/
│   ├── planner.md      # Planner system prompt
│   ├── coder.md        # Generator system prompt
│   ├── tester.md       # Evaluator system prompt
│   └── reviewer.md     # Reviewer system prompt
├── templates/
│   └── sprint.md       # Sprint file template
├── install.sh          # Installer
└── CLAUDE.md           # Claude Code project instructions
```
