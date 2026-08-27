---
name: homelab-one-off
description: Apply and record a single ad hoc fix to a live homelab host, with the diff shown before anything changes. Use for a one-off fix or repair, or when a health check found something to correct.
---

# Homelab One-Off Fix

A one-off is a fix applied now to one host.
Its durable operator record is part of the fix, not paperwork after it.

Resolve the operator notes root in this order: `HOMELAB_NOTES_DIR`, `$HOME/projects/agentic-notes`, then a sibling `agentic-notes` checkout beside this repository.
When a checkout exists, read and follow its root `AGENTS.md` before using its incident ledger.
When none exists, ask the operator where one-off evidence is recorded before applying a live change.
Do not create private operational state inside this public repository.

## 1. Establish the fault

Reproduce it read-only, from the outside, the way it presents.
Name the host and the evidence before proposing anything; a fix aimed at a pattern-matched cause repairs the wrong thing convincingly.

## 2. Check whether this is the second time

Search the resolved incident ledger for the host and the symptom.

A previous entry changes the work: the durable fix belongs in `host_baseline` or the relevant role, so the estate stops needing the same repair.
Say so, and propose that instead.

## 3. Show the diff, then ask

Run the mutating target without `APPLY=1` and show what it would change.
Applying is the operator's call every time: state the host, the change, and its blast radius, and wait for a clear yes.
`APPLY=1` goes on the command only after that answer.

Mutating runs happen from one machine at a time; there is no lock.

## 4. Verify against the live system

Re-run the read-only check that showed the fault and confirm it now passes.
Complete when the original evidence is gone, not when the command exited zero.

## 5. Record it

Record the date, host, symptom, command or action, and verification evidence in the operator's incident ledger.
Update any living state notes required by that checkout's instructions, then commit and push it in the same session.
