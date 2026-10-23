# retro-z80

A Z80 computer in the FPGA of a ZX Spectrum Next (KS2 for bring-up, KS3 for the full machine): retro68k narrowed to 8 bits (clone `jonsole/retro68k` next to this repo).

- Start with `docs/HANDOFF.md`: state of the project, unfinished work, next phase.
- Decisions: `docs/design-plan.md` (decision table in section 1 is binding). Specs: `docs/spec/`. Work: GitHub Issues.
- The user decides through a decision tree: 1–4 multiple-choice questions at a time, recommended option first, then write the answers into the plan and specs.
- Spec style follows retro68k's specs: plain short sentences, British spelling, tables, a test plan and open points.
- Phase 1 (the simulated CPU) is being built, ticket by ticket.

## Working with retro68k

retro68k and retro-z80 work towards one goal: the same machine, with a 68000 and with a Z80. retro68k is further ahead and still changing, so its files can lag its latest thinking. Sharing with its session matters as much as reading its files.

- Before deciding or inventing anything in the chipset, check retro68k's specs, guides, RTL and recent commits, and follow them unless the Z80 forces a difference (record it in the spec's "Comparison with retro68k").
- When unsure, ask the retro68k session directly: find it with ListAgents (it has run as `retro68k-f2`) and use SendMessage. Don't guess.
- Tell it what retro-z80 decides or finds that could matter to retro68k: spec errors, simplifications, bugs, tool problems. Answer its questions promptly.
- Copy retro68k RTL only from a committed, tested state, and record it in `fpga/rtl/PROVENANCE.md`.
- Never edit the retro68k repo from here; suggest changes to its session instead.

## Agent skills

### Issue tracker

GitHub Issues on jonsole/retro-z80, through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context. Decisions: `docs/design-plan.md` section 1; specs `docs/spec/`. See `docs/agents/domain.md`.
