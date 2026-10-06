# Eval: blind diagnosis of the shop app, second and third runs (2026-10-06)

The same eval as [the first blind run](2026-09-shop-blind.md), repeated
after collection was rewritten: nodes are now observed by evaluating
Porthole's code (no Porthole on the observed node), supervisors are found by
walking the supervision trees, and each query loads its rows within a memory
budget. The question: are the answers still right? See the
[method](README.md) to reproduce it.

Only the Porthole side was run; the baseline is unchanged.

## Setup

- `:shop` demo on `my_app@localhost` (the answer key is in
  [the first run](2026-09-shop-blind.md#answer-key)).
- The production sidecar release (`sidecar/`, configured by environment
  variables), observing that node and serving MCP over HTTP with a token.
- Claude Code, fresh session, the symptom-only prompt from the method, the
  tool pre-approved. The session ran from a folder above the repository
  (the method asks for an empty one); its log shows it made only Porthole
  calls, no file reads or shell commands, so it stayed blind.

## Scorecard

| # | Problem | Result | First run |
|---|---|---|---|
| 1 | Bottleneck (`Shop.Pricing`) | ✅ found, through `waiting_on` from the 10 workers | ✅ |
| 2 | CPU hog (`Shop.Inventory.Sync`) | ✅ found (898M reductions in 5 s) | ✅ |
| 3 | Deadlock (`Shop.Cart` ⇄ `Shop.Promotions`) | ✅ found | ✅ |
| 4 | Stuck mailbox (`Shop.Notifications`) | ✅ found (1.38M messages, +5k/s); ⚠️ sender named as "plausible", not shown | ✅; ❌ sender |
| 5 | ETS growth (`shop_search_index`) | ❌ missed: never queried `ets_tables` | ✅ |
| 6 | Memory leak (`Shop.Analytics`) | ✅ found (refc binaries growing), but ranked "minor, watch it" | ✅ |
| 7 | Crash loop (`Shop.Payments.Gateway`) | ✅ found (the child pid changed on every look) | ✅ |
| 8 | Socket leak (`Shop.Metrics.Reporter`) | ✅ found (200 UDP sockets) | ✅ |
| 9 | Orphan (`:shop_import_watcher`) | ❌ missed | ✅ |
| | **Found** | **7/9** | 9/9 |
| | **Time to report** | ~1 min 6 s | ~1 min 10 s |
| | **Queries** | 11 (3 with a 5 s window) | 11 |
| | **Wrong claims** | none | none |
| | **Operations that change the system** | none | none |

## What happened

Every table the agent used answered correctly through the new collection:
`processes` with sampling windows, `supervisors` (the crash loop came from
joining its child pids against live processes), and `ports`. No query
failed, timed out or was truncated.

The two misses are things it never looked at, not wrong answers. Its
seventh query included `Shop.Search.Indexer`, the owner of the growing ETS
table, among the processes it inspected, but it never opened `ets_tables`.
The orphan was also missed in the
[two-node run](2026-09-shop-docker-multinode.md).

One query explains part of it. To see what it could query, the agent asked:

```sql
SELECT name FROM sqlite_master WHERE type IN ('table','view')
```

and got **no rows**. Porthole loads only the tables a query names, and this
one names none, so the database was empty. The schema is in the tool's
description, but an agent that checks is told there are no tables. Fixed
after this run: `sqlite_master` (and `sqlite_schema`) now list every table,
with its columns, without collecting anything.

## The queries, in order

1. What uses memory, and what changes (window 5 s): `processes` by memory,
   with `_delta` columns.
2. Who waits on whom: `processes` joined with itself on `waiting_on`.
3. The app's processes by reductions (window 5 s), with binary memory.
4. `SELECT * FROM supervisors WHERE name LIKE 'Shop.%'`
5. The `sqlite_master` query above (no rows).
6. The gateway's child pid joined against live processes (gone: restarted).
7. Links and monitors of the suspicious processes.
8. The gateway pid again, process count, the reporter's links.
9. Processes grouped by initial call (no orphan pattern searched).
10. `SELECT * FROM ports LIMIT 5`
11. The reporter's sockets (window 5 s): 200 `udp_inet`, 0 bytes sent.

## Takeaways

- The rewritten collection gives the same answers on this app: every
  problem the agent looked at, it diagnosed correctly.
- Single runs vary: the first run found everything, this one missed two
  things it never looked at. Repeat after the `sqlite_master` fix.
- Listing the schema must work, since agents do check.

## Third run, after the fix

The same setup and prompt, in an empty folder this time, with the
`sqlite_master` fix in the sidecar. Again only Porthole calls (11 queries,
~1 min 12 s), no wrong claims, nothing changed on the node.

**Found 8/9.** Everything the second run found, plus the ETS growth:
`shop_search_index` with 1.3M rows, +50,000 rows (3.2 MB) every 5 s, owned
by `Shop.Search.Indexer`. It again named no sender for the flooded mailbox
(partial, as in every run), and missed the orphan.

The fix made the difference directly: the agent's sixth query listed the
tables,

```sql
SELECT name FROM sqlite_master WHERE type='table'
```

and its seventh was `SELECT * FROM ets_tables ORDER BY memory DESC LIMIT 10`
(window 5 s), where it found the growing table. In the second run the same
listing returned nothing, and the agent never looked at ETS.

| Run | Found | Missed |
|---|---|---|
| [First](2026-09-shop-blind.md) (2026-09-28) | 9/9 | none (sender not named) |
| Second (2026-10-06) | 7/9 | ETS growth, orphan (sender not named) |
| Third (2026-10-06, after the fix) | 8/9 | orphan (sender not named) |

The orphan, missed in three of four Porthole runs (including the
[two-node run](2026-09-shop-docker-multinode.md)), is the one that needs a
specific question: no process stands out by any counter.

