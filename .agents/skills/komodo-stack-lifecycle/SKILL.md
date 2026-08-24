---
name: komodo-stack-lifecycle
description: Add or remove a Komodo-managed application stack across homelab-infra, komodo-app-stacks, komodo-resource-syncs, and deploy-komodo-op. Use for stack onboarding, retirement, resource-sync cleanup, or cross-repository stack lifecycle checks.
---

# Komodo Stack Lifecycle

Treat repository files as rebuildable shape and the running Komodo Core as deployment state.
Resolve all participating repository roots before editing, and preserve each repository's own `AGENTS.md` rules.

## Add a stack

Read [references/add-stack.md](references/add-stack.md) in full, then follow it through its verification section.
The work is complete only when every applicable cross-repository item is accounted for and the stack validator passes.
Triggering a sync or deployment is a live mutation and requires the user's explicit authorization.

## Remove a stack

Read [references/remove-stack.md](references/remove-stack.md) in full before proposing or making a removal.
Establish the running Core's deletion semantics with the disposable-stack test before declaring the procedure verified.
The work is complete only when the runtime disposition, persistent-data decision, secret and variable cleanup, routes, monitors, homepage entries, and remaining repository references are all accounted for.

## Safety seam

Use `homelab-infra/bin/komodo` for Komodo API reads and for explicitly authorized writes.
Keep discovery and planning read-only.
Never infer that removing a declaration deletes runtime resources or persistent data.
Record live verification or one-off repair evidence in the private `agentic-notes` checkout in the same session.
