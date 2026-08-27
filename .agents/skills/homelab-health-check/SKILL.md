---
name: homelab-health-check
description: Answer whether the managed homelab passes its read-only checks and, when operator notes exist, still matches their claims. Use for a health check, a status report, "is anything broken", or a spot check before or after other work.
---

# Homelab Health Check

Read-only throughout.
The deliverable is the live failures and unknowns, plus any delta from configured operator notes.
A report that merely restates notes has not done the work.

## 1. Resolve optional operator notes

Resolve the notes root in this order: `HOMELAB_NOTES_DIR`, `$HOME/projects/agentic-notes`, then a sibling `agentic-notes` checkout beside this repository.
When one exists, read its root `AGENTS.md`, pull it `--ff-only`, then read the estate and repository notes relevant to the requested checks.
Reading the claim first is what makes a delta visible.

A missing notes checkout or failing pull is reported as an unavailable comparison lane and never blocks the live checks.
Do not assume that a fork operator uses the reference deployment's vault structure.

## 2. Gather evidence

Run the lane for the repository present on this machine:

- `homelab-infra`: `make verify`, then narrower `make verify TAGS=<tag>` runs for anything that failed.
- `ha-config`: `hactl validate` and `hactl drift` for every instance, without `--pull`.

Every mutating target defaults to a dry run, and this skill leaves it that way.
A check that cannot run is reported as unknown, which is a different answer from healthy.

## 3. Report the deltas

Complete when every failing check and every contradiction between evidence and notes is accounted for, each with the command that showed it.
Lead with the answer: healthy, or the specific thing that is not.
Green checks that agree with the notes are one line in total, not a list.

## 4. Land the finding when operator notes are configured

When an operator notes checkout was resolved, correct what the evidence contradicts in the locations defined by its own `AGENTS.md`.
Commit and push that checkout before answering.
When no notes checkout exists, report the exact live evidence and the missing durable-record destination without creating one inside this public repository.

Fixing what the check found is [homelab-one-off](../homelab-one-off/SKILL.md), and it starts by asking.
