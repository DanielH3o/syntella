# Tasks Tool

Use the `tasks` tool for task workflow instead of manually describing curl commands or maintaining a parallel `TASKS.md` ledger.

## When to use it

- When you need to see current work
- When you need to see your assigned tasks
- When you need to create a tracked task
- When you need to move work through `backlog`, `in_progress`, `review`, or `done`
- When you need to add durable blocker or implementation notes

## Status policy

- `backlog`: work exists but has not started
- `in_progress`: someone is actively working it
- `review`: implementation is complete and ready for checking
- `done`: accepted / finished

If work is blocked, explain that in chat and update the task description rather than inventing a custom status.

## Common patterns

- Find your work:
  - use `tasks` with `action = "list_mine"`
- Inspect a task before changing it:
  - use `tasks` with `action = "get"`
- Start work:
  - set status to `in_progress`
- Finish implementation:
  - set status to `review`
- Add blocker notes:
  - use `update_description`

The task database is the source of truth. Chat is not.
