# an-agents-skill

A collection of my personal [Agent Skills](https://skills.sh) - reusable instructions that extend AI coding agents (Claude Code, OpenCode, Cursor, Copilot, and others) with new capabilities.

## Available skills

| Skill | Description |
| --- | --- |
| [`vertex-run-insights`](skills/vertex-run-insights/SKILL.md) | Inspect Vertex AI pipeline runs in JET's ML platform (jet-ml-dev / jet-ml-staging / jet-ml-prod, europe-west1) and report per-task CPU and RAM peaks, runtimes, machine types and USD cost. |

## Install

Install all skills from this repo:

```bash
npx skills add thanthanhan93/an-agents-skill
```

Install a single skill:

```bash
npx skills add thanthanhan93/an-agents-skill --skill vertex-run-insights
```

Install globally (available across all projects):

```bash
npx skills add thanthanhan93/an-agents-skill -g
```

List the skills in this repo without installing:

```bash
npx skills add thanthanhan93/an-agents-skill --list
```

For non-interactive installs (CI-friendly), add `-y` and target agents explicitly:

```bash
npx skills add thanthanhan93/an-agents-skill --skill vertex-run-insights -g -a claude-code -y
```

## Repository layout

```
skills/
  <skill-name>/
    SKILL.md          # Required: frontmatter (name, description) + instructions
    references/       # Optional: supporting docs loaded on demand
    scripts/          # Optional: helper scripts the skill calls
    evals/            # Optional: evaluation cases
```

Each skill lives in its own directory whose name matches the `name` field in its `SKILL.md` frontmatter.
The `npx skills` CLI discovers every directory under `skills/` that contains a `SKILL.md`.

## Adding a new skill

Scaffold a new skill, then move it under `skills/`:

```bash
npx skills init my-new-skill
mv my-new-skill skills/
```

Or create it by hand:

```
skills/my-new-skill/SKILL.md
```

```markdown
---
name: my-new-skill
description: What the skill does and when the agent should use it.
---

# My New Skill

Instructions for the agent...
```

The `name` must match the directory name, and both `name` and `description` are required.

## License

[MIT](LICENSE)
