#!/usr/bin/env bash
# lib/harness.sh — GAN-style harness orchestration
# Implements the Planner → Generator → Evaluator loop from
# https://www.anthropic.com/engineering/harness-design-long-running-apps
#
# Key insight: separate the agent that PRODUCES work from the agent that
# EVALUATES it, because Claude consistently over-praises its own output.
#
# This harness supports two modes:
#   1. Interactive (tmux panes) — agents run as persistent Claude Code sessions
#   2. Headless (claude -p) — agents run as one-shot commands with context resets

HARNESS_SCORE_THRESHOLD="${HARNESS_SCORE_THRESHOLD:-7.0}"
HARNESS_MAX_ITERATIONS="${HARNESS_MAX_ITERATIONS:-10}"
HARNESS_PLATEAU_TOLERANCE="${HARNESS_PLATEAU_TOLERANCE:-2}"

# ─── Headless Harness (claude -p pipeline) ──────────────────────────────────

# Run the planner phase: expand a brief prompt into a full spec
# Usage: squad_harness_plan <squad_dir> <prompt> [model]
squad_harness_plan() {
  local squad_dir="$1"
  local prompt="$2"
  local model="${3:-claude-opus-4-6}"
  local spec_file="${squad_dir}/spec.md"
  local rubric_file="${squad_dir}/eval-rubric.md"

  echo "=== PLANNER PHASE ===" >&2
  echo "Expanding prompt into spec and evaluation rubric..." >&2

  claude -p --model "$model" \
    "You are the Planner agent in a GAN-style development harness.

Your job: take the user's brief prompt and expand it into:
1. A comprehensive product specification (spec.md)
2. An evaluation rubric (eval-rubric.md)

## Spec Requirements
- Be ambitious about scope — push the boundaries of what can be built
- Focus on HIGH-LEVEL deliverables, not implementation details
- Break work into numbered sprints (aim for 3-8 sprints)
- Each sprint should have clear, testable deliverables
- Include a visual design language section

## Evaluation Rubric Requirements
Create scoring criteria (1-10 scale) for:
1. Product depth — does it go beyond surface-level?
2. Functionality — does everything actually work?
3. Visual design — cohesive, polished UI?
4. Code quality — clean, maintainable, no dead code?

Each criterion needs:
- Description of what 1, 5, and 10 look like
- Hard pass/fail threshold (minimum score to pass)

## Output Format
Write TWO files:
- First, output the spec between <spec> tags
- Then, output the rubric between <rubric> tags

USER PROMPT: ${prompt}" > "${squad_dir}/.planner-output.tmp"

  # Parse the output into separate files
  sed -n '/<spec>/,/<\/spec>/p' "${squad_dir}/.planner-output.tmp" | sed '1d;$d' > "$spec_file"
  sed -n '/<rubric>/,/<\/rubric>/p' "${squad_dir}/.planner-output.tmp" | sed '1d;$d' > "$rubric_file"
  rm -f "${squad_dir}/.planner-output.tmp"

  # Validate output
  if [[ ! -s "$spec_file" ]]; then
    echo "Warning: spec.md is empty — planner may have failed" >&2
    return 1
  fi

  echo "Spec: $(wc -l < "$spec_file") lines" >&2
  echo "Rubric: $(wc -l < "$rubric_file") lines" >&2
  echo "$spec_file"
}

# Run a single generator iteration
# Usage: squad_harness_generate <squad_dir> <work_dir> <sprint_num> [model]
squad_harness_generate() {
  local squad_dir="$1"
  local work_dir="$2"
  local sprint_num="$3"
  local model="${4:-claude-opus-4-6}"
  local spec_file="${squad_dir}/spec.md"
  local feedback_file="${squad_dir}/feedback-sprint-${sprint_num}.md"
  local iteration_file="${squad_dir}/iteration-${sprint_num}.txt"

  local iteration=1
  if [[ -f "$iteration_file" ]]; then
    iteration=$(( $(cat "$iteration_file") + 1 ))
  fi
  echo "$iteration" > "$iteration_file"

  echo "=== GENERATOR PHASE (Sprint $sprint_num, Iteration $iteration) ===" >&2

  local feedback_context=""
  if [[ -f "$feedback_file" ]] && [[ -s "$feedback_file" ]]; then
    feedback_context="

## Previous Evaluation Feedback
$(cat "$feedback_file")

IMPORTANT: Address every bug and issue listed above. Do NOT just add surface-level polish.
Focus on the specific failures identified by the evaluator."
  fi

  # Run generator with fresh context (context reset, not compaction)
  cd "$work_dir" && claude -p --model "$model" \
    --dangerously-skip-permissions \
    "You are the Generator agent in a GAN-style development harness.
You are implementing Sprint ${sprint_num} of the project spec.

## Project Spec
$(cat "$spec_file")

## Your Task
Implement the deliverables for Sprint ${sprint_num}.
This is iteration ${iteration} — if there's previous feedback, fix every issue.
${feedback_context}

## Rules
- Write real, working code — not stubs or placeholders
- Test your work by running it before declaring done
- Commit your changes with a clear message
- If this is iteration > 1, focus ONLY on fixing the feedback — don't refactor unrelated code"

  echo "Generator iteration $iteration complete" >&2
}

# Run the evaluator phase using Playwright for testing
# Usage: squad_harness_evaluate <squad_dir> <work_dir> <sprint_num> [model]
# Returns: score (float) on stdout, feedback written to file
squad_harness_evaluate() {
  local squad_dir="$1"
  local work_dir="$2"
  local sprint_num="$3"
  local model="${4:-claude-opus-4-6}"
  local rubric_file="${squad_dir}/eval-rubric.md"
  local spec_file="${squad_dir}/spec.md"
  local feedback_file="${squad_dir}/feedback-sprint-${sprint_num}.md"
  local score_file="${squad_dir}/score-sprint-${sprint_num}.txt"

  echo "=== EVALUATOR PHASE (Sprint $sprint_num) ===" >&2
  echo "Testing the implementation with Playwright..." >&2

  cd "$work_dir" && claude -p --model "$model" \
    "You are the Evaluator agent in a GAN-style development harness.
Your job is to rigorously test and evaluate Sprint ${sprint_num}.

CRITICAL: You must be SKEPTICAL and THOROUGH. Do NOT rationalize issues as acceptable.
If something doesn't work, it FAILS. Period.

## Project Spec
$(cat "$spec_file")

## Evaluation Rubric
$(cat "$rubric_file")

## Your Evaluation Process
1. Read the code that was implemented
2. Start the application if applicable
3. Use Playwright CLI (npx playwright test, or write test scripts) to:
   - Navigate the UI as a real user would
   - Click buttons, fill forms, verify outputs
   - Test edge cases and error states
4. Score each rubric criterion (1-10 scale)
5. File specific bugs for anything that fails

## Output Format
Output your evaluation between <evaluation> tags:
<evaluation>
## Scores
- Product depth: X/10
- Functionality: X/10
- Visual design: X/10
- Code quality: X/10
- OVERALL: X/10

## Bugs Filed
1. [BUG] Description — Expected vs Actual
2. ...

## Detailed Feedback
(Paragraph explaining what works, what doesn't, specific issues to fix)
</evaluation>

BE HARSH. The generator benefits from honest, critical feedback.
Finding bugs is your PRIMARY VALUE — not being encouraging." > "${squad_dir}/.evaluator-output.tmp"

  # Parse evaluation
  local eval_output
  eval_output=$(sed -n '/<evaluation>/,/<\/evaluation>/p' "${squad_dir}/.evaluator-output.tmp" | sed '1d;$d')

  if [[ -z "$eval_output" ]]; then
    # Fallback: use the entire output
    eval_output=$(cat "${squad_dir}/.evaluator-output.tmp")
  fi

  echo "$eval_output" > "$feedback_file"

  # Extract overall score
  local score
  score=$(echo "$eval_output" | grep -i "OVERALL" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
  if [[ -z "$score" ]]; then
    score="5.0"
    echo "Warning: could not parse score, defaulting to 5.0" >&2
  fi
  echo "$score" > "$score_file"

  rm -f "${squad_dir}/.evaluator-output.tmp"

  echo "Score: $score / 10" >&2
  echo "$score"
}

# Run the full harness loop for one sprint
# Usage: squad_harness_sprint <squad_dir> <work_dir> <sprint_num> [model]
squad_harness_sprint() {
  local squad_dir="$1"
  local work_dir="$2"
  local sprint_num="$3"
  local model="${4:-claude-opus-4-6}"

  local prev_score=0
  local plateau_count=0
  local _hs_score _hs_improvement

  for ((iter = 1; iter <= HARNESS_MAX_ITERATIONS; iter++)); do
    echo "" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "Sprint $sprint_num — Iteration $iter / $HARNESS_MAX_ITERATIONS" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2

    # Generator builds/fixes
    squad_harness_generate "$squad_dir" "$work_dir" "$sprint_num" "$model"

    # Evaluator tests and scores
    _hs_score=$(squad_harness_evaluate "$squad_dir" "$work_dir" "$sprint_num" "$model")

    # Check if we've passed the threshold
    if (( $(echo "$_hs_score >= $HARNESS_SCORE_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
      echo "" >&2
      echo "PASSED! Score $_hs_score >= threshold $HARNESS_SCORE_THRESHOLD" >&2
      return 0
    fi

    # Check for score plateau (improvement stalled)
    _hs_improvement=$(echo "$_hs_score - $prev_score" | bc -l 2>/dev/null || echo "0")
    if (( $(echo "$_hs_improvement <= 0.5" | bc -l 2>/dev/null || echo 0) )); then
      plateau_count=$((plateau_count + 1))
      echo "Plateau detected ($plateau_count / $HARNESS_PLATEAU_TOLERANCE)" >&2
    else
      plateau_count=0
    fi

    if (( plateau_count >= HARNESS_PLATEAU_TOLERANCE )); then
      echo "" >&2
      echo "PLATEAU: Score not improving after $HARNESS_PLATEAU_TOLERANCE iterations. Moving on." >&2
      return 1
    fi

    prev_score=$_hs_score
  done

  echo "MAX ITERATIONS reached for sprint $sprint_num" >&2
  return 1
}

# Run the full harness: plan → sprint loop
# Usage: squad_harness_run <prompt> <work_dir> [model]
squad_harness_run() {
  local prompt="$1"
  local work_dir="$2"
  local model="${3:-claude-opus-4-6}"
  local squad_dir="${work_dir}/.squad"

  mkdir -p "$squad_dir"

  echo "╔══════════════════════════════════════════════╗" >&2
  echo "║  Claude Squad — GAN-Style Harness            ║" >&2
  echo "║  Planner → Generator → Evaluator Loop        ║" >&2
  echo "╚══════════════════════════════════════════════╝" >&2
  echo "" >&2

  # Phase 1: Planning
  squad_harness_plan "$squad_dir" "$prompt" "$model"

  # Count sprints from spec
  local num_sprints
  num_sprints=$(grep -cE "^##? Sprint" "${squad_dir}/spec.md" 2>/dev/null || echo "3")
  if [[ "$num_sprints" -lt 1 ]]; then
    num_sprints=3
  fi

  echo "" >&2
  echo "Plan complete: $num_sprints sprints identified" >&2
  echo "" >&2

  # Phase 2: Sprint loop
  local passed=0
  local failed=0
  for ((s = 1; s <= num_sprints; s++)); do
    echo "" >&2
    echo "╔══════════════════════════════════════════════╗" >&2
    echo "║  Sprint $s / $num_sprints                              ║" >&2
    echo "╚══════════════════════════════════════════════╝" >&2

    if squad_harness_sprint "$squad_dir" "$work_dir" "$s" "$model"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
  done

  echo "" >&2
  echo "╔══════════════════════════════════════════════╗" >&2
  echo "║  HARNESS COMPLETE                             ║" >&2
  echo "║  Passed: $passed / $num_sprints sprints                   ║" >&2
  echo "║  Failed: $failed / $num_sprints sprints                   ║" >&2
  echo "╚══════════════════════════════════════════════╝" >&2
}

# ─── Interactive Harness (tmux-based) ────────────────────────────────────────

# Generate sprint contract between generator and evaluator
# Usage: squad_harness_write_contract <squad_dir> <sprint_num> <deliverables>
squad_harness_write_contract() {
  local squad_dir="$1"
  local sprint_num="$2"
  local deliverables="$3"
  local contract_file="${squad_dir}/contract-sprint-${sprint_num}.md"

  cat > "$contract_file" << HEREDOC
# Sprint Contract — Sprint ${sprint_num}
Date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Status: ACTIVE

## Deliverables
${deliverables}

## Success Criteria
- [ ] All deliverables implemented and functional
- [ ] No regressions in previously passing tests
- [ ] Code compiles/runs without errors
- [ ] UI elements are interactive and visually correct

## Evaluation Method
The evaluator will test each deliverable using Playwright and manual inspection.
Each criterion is scored 1-10. Minimum passing score: ${HARNESS_SCORE_THRESHOLD}/10.
HEREDOC

  echo "$contract_file"
}

# Write a progress file for the current harness state
# Usage: squad_harness_write_progress <squad_dir>
squad_harness_write_progress() {
  local squad_dir="$1"
  local progress_file="${squad_dir}/progress.md"

  echo "# Harness Progress" > "$progress_file"
  echo "Updated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$progress_file"
  echo "" >> "$progress_file"

  # Collect all sprint scores
  local _pr_num _pr_score _pr_iter
  for score_file in "${squad_dir}"/score-sprint-*.txt; do
    if [[ -f "$score_file" ]]; then
      _pr_num=$(basename "$score_file" | grep -oE '[0-9]+')
      _pr_score=$(cat "$score_file")
      _pr_iter="?"
      if [[ -f "${squad_dir}/iteration-${_pr_num}.txt" ]]; then
        _pr_iter=$(cat "${squad_dir}/iteration-${_pr_num}.txt")
      fi
      echo "- Sprint $_pr_num: Score $_pr_score/10 (${_pr_iter} iterations)" >> "$progress_file"
    fi
  done
}
