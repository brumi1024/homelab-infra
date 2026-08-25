---
name: homelab-health-check
description: Answer whether the homelab still matches what the notes claim, using read-only checks only. Use for a health check, a status report, "is anything broken", or a spot check before or after other work.
---

# Homelab Health Check

Read-only throughout.
The deliverable is the **deltas**: what the live estate does that the vault does not already say.
A report that restates the vault has not done the work.

## 1. Take the vault's claim first

Pull the `agentic-notes` checkout `--ff-only`, then read `Estate/Homelab Overview.md` and the site note for anything the checks will touch.
Reading the claim first is what makes a delta visible; checks read without it are just output.

A failing pull is noted in the answer and never blocks the rest.

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

## 4. Land the finding in the same session

Correct what the evidence contradicts: estate facts in `Estate/`, repo state in `Repos/`, and stamp `verified` on any living note checked against the live system.
Commit and push the vault before answering; a note that lags the estate is a defect.

Fixing what the check found is [homelab-one-off](../homelab-one-off/SKILL.md), and it starts by asking.
