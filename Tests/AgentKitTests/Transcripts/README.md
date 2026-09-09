Recorded `claude -p --output-format stream-json --verbose` transcripts used as parser fixtures.

- `live-project-list.stream.jsonl`: the one live headless run (Claude Code 2.1.265, 2026-09-08) with the goal "call project_list and report the result"; paths scrubbed, no tokens present.
- `fake-turn1.stream.jsonl`, `fake-turn2.stream.jsonl`: hand-written turns the fake `claude` script replays in `ClaudeCodeRuntimeTests` (an approval_required result, an image block, a `--resume` follow-up).
