# Evals

Does an agent with Porthole diagnose a live BEAM system better than an agent
with only a shell? These evals answer that question with runs anyone can
reproduce.

## Method

### The system under test

`Porthole.Demo.start/1` starts `:shop`, a small OTP application with nine
planted problems: a serializing bottleneck, a CPU hog, a deadlock, a stuck
mailbox, a growing ETS table, a memory leak, a crash-looping child, a socket
leak and an orphan process.

The eval is **blind**. Everything an agent can observe at runtime (module and
registered names, ETS tables, child ids, the application) looks like an
ordinary app. The answer key lives only in the demo's source, so **agents
must run from a directory that does not contain this repository**.

### Setup

```console
# The target node, from a checkout of this repository.
$ iex --sname my_app@localhost --cookie dev -S mix run -e 'Porthole.Demo.start()'
```

For the **Porthole** run, start the sidecar and connect the agent over HTTP
(see [Setting up your team](../guides/team-setup.md#production)):

```console
$ mix porthole.gen.token eval     # put the entry in config/config.exs
$ mix porthole.server --connect my_app@localhost --cookie dev
$ claude mcp add --transport http porthole http://127.0.0.1:4040/ --header "Authorization: Bearer ph_..."
```

For the **baseline** run, the agent gets no Porthole, only its shell and the
node's name and cookie (so it can use Erlang distribution: a remote console,
`:erpc`, scripts).

Before each run, restart the demo so both start from the same state
(`Porthole.Demo.start()` in the target's iex restarts it), then start a fresh
agent session in an empty directory **outside this repository** (an agent
that is waiting on something will browse the files around it):

```console
$ mkdir -p ~/porthole-eval && cd ~/porthole-eval && claude
```

Register the MCP server in that directory (`claude mcp add` is per
directory by default), and allow the tool up front (`/permissions`, allow
`mcp__porthole__query`): Claude Code's auto-mode check intermittently
failed on it during our runs, and a read-only tool does not need it.

### Prompt

The same symptom-only prompt for both runs. No table names, no hints:

> Our app running on `my_app@localhost` is misbehaving: it feels slow and
> memory seems to be creeping up. You have the porthole tool to inspect the
> live system. Investigate and tell me what's wrong, with evidence.

For the baseline, the tool sentence is replaced by: *"You can reach the node
over Erlang distribution: node `my_app@localhost`, cookie `dev`."*

### Scoring

For each planted problem: **found** (identified the right process or table
with correct evidence), **partial** (right area, wrong or missing culprit), or
**missed**. Also record:

- time to the final report, and the number of tool calls or commands;
- claims that are wrong;
- **anything that could change the system** (killing processes, `:sys`
  calls, evaluating code with side effects). Porthole cannot do these; a
  shell can. Read the agent's session log (not just its final report): the
  report may say it changed nothing when its commands say otherwise.

Stop the demo when done (`Porthole.Demo.stop()`): it grows without bound by
design.

## Results

| Eval | Date | Porthole | Baseline |
|---|---|---|---|
| [Shop, blind](2026-09-shop-blind.md) | 2026-09-28 | 9/9 found, 11 queries, ~1 min, no changes to the node | 7/9 found, 1 wrong claim, ~2 min, copied a whole mailbox and table, ran app code, enabled tracing |
| [Shop, two nodes, Docker sidecar](2026-09-shop-docker-multinode.md) | 2026-09-28 | 8/9 found (missed the orphan), 16 queries, ~1.5 min, both nodes covered without being told | not run |
| [Shop, blind, second run](2026-10-shop-blind.md) | 2026-10-06 | 7/9 found (missed the ETS growth and the orphan, which it never looked at), 11 queries, ~1 min, no wrong claims; after collection was rewritten | not run |
