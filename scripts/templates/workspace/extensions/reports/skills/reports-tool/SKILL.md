# Reports Tool

Use the `reports` tool whenever a result needs to be durable, reviewable later, or tied to a routine.

## When to use it

- When a routine calls for a report
- When you need to leave a durable summary beyond chat
- When work produced findings, recommendations, or an audit trail
- When Discord should only get a short summary but the full output should be saved

## What goes in a report

- `title`: clear and specific
- `summary`: short executive summary
- `body`: the full durable output
- `report_type`: use something meaningful like `routine`, `analysis`, `review`, or `audit`

## Common patterns

- Save a routine result:
  - use `reports` with `action = "create"`
  - set `report_type = "routine"`
- Save a longer investigation:
  - use `reports` with `action = "create"`
  - keep chat short and put the full detail in `body`
- Review recent durable outputs:
  - use `reports` with `action = "list_recent"` or `list_mine`

Chat is for short updates. Reports are for durable output.
