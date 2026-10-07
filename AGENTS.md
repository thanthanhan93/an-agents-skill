# AGENTS.md

Guidance for agents working in this repository.

## What this repo is

This repo is the published collection of my personal agent skills, laid out as `skills/<name>/SKILL.md`.
The repo is the source of truth, but it is **not** where I author skills day to day.
I create and iterate on skills locally inside the agent I am using (Claude Code, OpenCode, pi, ...), and the local copy is usually newer than the repo.
So the repo regularly lags behind what is installed locally.

## Rule: pull my latest local skills into this repo

Whenever you are asked to "push", "sync", "update the repo", or add a skill, do not assume the repo is current.
First check my local skill directories, find the skills I authored that are new or newer than the repo copy, copy the latest local version into `skills/<name>/`, and commit.

## Where my local skills live

Skills are authored in different places depending on the agent.
Check all of these, not just one.

| Agent | User-level skills dir | Project-level skills dir |
| --- | --- | --- |
| Shared / canonical | `~/.agents/skills/` | `<project>/.agents/skills/` |
| Claude Code | `~/.claude/skills/` | `<project>/.claude/skills/` |
| OpenCode | `~/.config/opencode/skills/` | `<project>/.opencode/skills/` |
| pi | `~/.pi/agent/skills/` | `<project>/.pi/skills/` |
| Other | `~/.agent/skills/` | |

Notes on these directories:

- `~/.agents/skills/` is the shared store, and `~/.claude/skills/` mostly contains symlinks pointing into it.
- A directory under `~/.claude/skills/` that is a real directory (not a symlink) is a skill that Claude owns directly, for example `~/.claude/skills/confluence-cli/`.
- The directory name on disk may differ from the published name in this repo, for example `~/.agents/skills/personal-mermaid-tool/` is published here as `skills/mermaid-tool/`.

## How to tell my skills from third-party ones

Skills I installed from other people via `npx skills add` are recorded in `~/.agents/.skill-lock.json`.
Use that file as the discriminator:

- A local skill listed in `~/.agents/.skill-lock.json` came from an external source and is **not** mine to publish.
- A local skill that is absent from the lock file is one I authored, and is a candidate to sync into this repo.

## How to find what needs syncing

List the local skills, then compare each candidate against the repo copy:

```bash
ls -la ~/.agents/skills ~/.claude/skills ~/.config/opencode/skills ~/.pi/agent/skills ~/.agent/skills 2>/dev/null
diff -rq ~/.agents/skills/<name> skills/<name>
```

A `diff -rq` that reports differences, or a local file whose mtime is newer than the repo file, means the local copy is ahead and should be pulled in.
Comparing mtimes is a good tie-breaker when the content looks close.

## Do not publish these

These are scratch or managed directories, not skills to ship:

- `<skill>-workspace/` directories, for example `~/.agents/skills/vertex-run-insights-workspace/`. These are skill-creator eval scratch, including `skill-snapshot/` and `iteration-*/`.
- `~/.agents/skill-backups/`, which holds timestamped backups made by the installer.
- The hashed buckets under `~/.claude/skills/synced/`, which are managed by Claude's skill sync.

## Sync procedure

1. Find local skills that are new or newer than the repo copy, ignoring the excluded directories above.
2. Copy the latest local files into `skills/<name>/`, preserving the `SKILL.md`, `references/`, `scripts/` and `evals/` layout.
3. Keep the published directory name matching the `name` field in the skill's `SKILL.md` frontmatter.
4. Update the "Available skills" table in `README.md` if a skill was added or renamed.
5. Commit on a feature branch and open a pull request. Only commit directly to `main` if I explicitly ask for it.
