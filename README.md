# Ultraviolet

Ultraviolet is a terminal-native purple team security operations platform built on **Elixir** and the **BEAM runtime**.

It combines:

- realtime telemetry ingestion
- alert and investigation lifecycle management
- terminal-first SOC operations
- bounded agent-assisted workflows using **Jido**
- AI interoperability through **MCP (Model Context Protocol)**

Ultraviolet is designed as a **research and experimentation platform** for autonomous and human-guided security operations.

This repository includes:

- the Ultraviolet platform
- the built-in MCP server
- Jido-based bounded agent components inside Ultraviolet

This repository does **not** include my external Hermes agent. Hermes was used as a development partner and can connect to Ultraviolet through MCP, but the private agent itself is not part of this codebase.

## Why Ultraviolet Exists

Most security platforms today are built around:

- large web dashboards
- centralized service layers
- conventional SIEM pipelines
- analyst workflows designed for browsers first

Ultraviolet explores a different direction:

- terminal-first operations
- actor-style concurrency on the BEAM
- bounded AI assistance
- structured security workflows
- agent-operable infrastructure

The goal is not to replace mature security platforms. The goal is to explore what a **realtime, terminal-native, AI-accessible security system** looks like when built from first principles in Elixir.

## High-Level Architecture

Ultraviolet is an **Elixir umbrella application**.

```text
apps/
  hacktui_agent/
  hacktui_collab/
  hacktui_core/
  hacktui_hub/
  hacktui_sensor/
  hacktui_store/
  hacktui_tui/
```

### `hacktui_core`

Shared domain logic and durable system concepts.

Contains:

- commands
- events
- aggregates
- investigation lifecycle logic
- alert lifecycle logic
- correlation and reporting primitives

### `hacktui_store`

Persistence boundary.

Responsible for storing and projecting:

- alerts
- cases
- observations
- approvals
- audit events
- query projections

Backed by Ecto and PostgreSQL.

### `hacktui_hub`

System control plane and runtime coordination layer.

Responsible for:

- health reporting
- query services
- alert promotion
- case creation
- investigation orchestration
- privacy masking
- replay support
- runtime workflows

### `hacktui_sensor`

Telemetry ingestion boundary.

Responsible for collecting and forwarding:

- journald security events
- network flow telemetry
- process/runtime signals

### `hacktui_tui`

Terminal SOC interface.

Responsible for rendering:

- alert queue
- case board
- approvals
- observations
- workflow views
- live dashboard views

### `hacktui_agent`

Bounded agent integration.

Uses the **real Jido runtime** for advisory investigation workflows and includes the MCP server implementation that external agents can use to interact with Ultraviolet.

### `hacktui_collab`

Experimental collaboration boundary for external integrations.

## What Ultraviolet Does

Ultraviolet currently supports:

- live host telemetry ingestion
- network flow ingestion through `tshark` / `dumpcap`
- journald security event ingestion
- process and BEAM runtime telemetry
- alert lifecycle management
- investigation case creation
- terminal-native SOC workflows
- MCP access for external AI agents
- Jido-backed agent runtime integration
- privacy masking for safer screenshots and demos

In practice, this means Ultraviolet can collect observations, promote suspicious activity into alerts, open cases, expose system state through MCP, and allow a bounded agent to assist with investigation while keeping a human operator in control.

## Major Design Principles

### Terminal First

Ultraviolet is built to work over SSH, in remote shells, and in environments where browser-first tooling is undesirable.

### Durable State

Alerts, cases, approvals, and observations are modeled explicitly and can be persisted and queried.

### Bounded Agent Assistance

Agents help analyze, summarize, and investigate. Humans remain in control of final decisions.

### Replayable Workflows

The platform is intended to support replay, validation, and purple-team experimentation.

### Auditable Operations

State transitions should leave inspectable records and remain understandable to operators.

## Technology Stack

- **Elixir**
- **Erlang/OTP**
- **BEAM**
- **PostgreSQL**
- **Ecto**
- **Jido**
- **MCP**
- **tshark / dumpcap**
- terminal UI workflows

## Requirements

Recommended versions:

- Elixir **1.19+**
- Erlang/OTP **28+**
- PostgreSQL **14+**
- `tshark`
- `dumpcap`

Useful optional tools:

- `journalctl`
- Observer GUI support
- `git`

Ultraviolet is currently best supported on **Linux**.

---

# Installation

## 1. Clone the repository

```bash
git clone https://github.com/ScriptKittyOS/Ultraviolet.git
cd Ultraviolet
```

## 2. Install Elixir dependencies

```bash
mix deps.get
```

## 3. Compile the umbrella

```bash
mix compile
```

## 4. Install required system packages

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y erlang elixir postgresql postgresql-contrib wireshark tshark
```

For Observer GUI support, you may also need:

```bash
sudo apt install -y libwxgtk3.2-dev libwxgtk-webview3.2-dev
```

### Fedora

```bash
sudo dnf install -y erlang elixir postgresql-server wireshark-cli wireshark
```

### Arch Linux

```bash
sudo pacman -S elixir erlang postgresql wireshark-cli wireshark-qt
```

## 5. Verify capture tools

```bash
which tshark
which dumpcap
```

Expected output should be valid paths such as:

```bash
/usr/bin/tshark
/usr/bin/dumpcap
```

---

# Database Setup

## 1. Start PostgreSQL

```bash
sudo systemctl start postgresql
sudo systemctl enable postgresql
```

## 2. Create a database user and database

```bash
sudo -u postgres psql
```

Inside `psql`:

```sql
CREATE USER hacktui WITH PASSWORD 'hacktui';
CREATE DATABASE hacktui_dev OWNER hacktui;
\q
```

## 3. Export runtime environment variables

```bash
export HACKTUI_START_REPO=true
export HACKTUI_DB_NAME=hacktui_dev
export HACKTUI_DB_USER=hacktui
export HACKTUI_DB_PASS=hacktui
export HACKTUI_DB_HOST=localhost
export HACKTUI_DB_PORT=5432
```

## 4. Run migrations

```bash
mix ecto.create
mix ecto.migrate
```

If your environment uses app-specific migration tasks, run the equivalent store migration workflow for your setup.

---

# Running Ultraviolet

## Start the full runtime in IEx

```bash
iex -S mix
```

## Ensure the main apps are started

```elixir
Application.ensure_all_started(:hacktui_store)
Application.ensure_all_started(:hacktui_hub)
Application.ensure_all_started(:hacktui_agent)
Application.ensure_all_started(:hacktui_sensor)
Application.ensure_all_started(:hacktui_tui)
```

## Check health

```elixir
HacktuiHub.Health.status()
HacktuiAgent.Health.status()
HacktuiHub.QueryService.system_diagnostic()
```

You should see the hub, store, and agent layers report healthy startup state.

---

# Launching the Terminal SOC Interface

Start the TUI:

```bash
mix hacktui.tui
```

Depending on your current implementation and workflow, you may also have an equivalent task exposed under the hub app. If so, this command should also work:

```bash
mix hacktui.live
```

The terminal UI is intended to display:

- alert queue
- case board
- approval inbox
- recent observations
- system health
- workflow-specific views

---

# Running Observer GUI

Observer is extremely useful for inspecting BEAM processes, supervision trees, memory, and message flow.

Start the project:

```bash
iex -S mix
```

Then launch Observer:

```elixir
:observer.start()
```

If your system requires explicit wx startup:

```elixir
:wx.new()
:observer.start()
```

Observer is useful for inspecting:

- supervision trees
- process state
- message queues
- ETS tables
- scheduler load
- application memory usage

---

# Verifying Jido Integration

Ultraviolet uses the **real Jido runtime**, not a local stub.

Run the following in IEx:

```elixir
Code.ensure_loaded?(Jido)
Code.ensure_loaded?(Jido.Agent)
Code.ensure_loaded?(Jido.Action)
```

All should return `true`.

Verify the application starts:

```elixir
Application.ensure_all_started(:jido)
Application.spec(:jido)
```

Locate the compiled modules:

```elixir
:code.which(Jido)
:code.which(Jido.Agent)
:code.which(Jido.Action)
```

Expected result: paths under `_build/dev/lib/jido/` and `_build/dev/lib/jido_action/`.

---

# Running the MCP Server

Ultraviolet includes a built-in MCP server.

## Start in stdio mode

```bash
HACKTUI_MCP_STDIO=1 ./bin/hacktui-mcp
```

## Quick initialize test

```bash
body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"demo","version":"0.1"}}}'
printf '%s\n' "$body" | ./bin/hacktui-mcp
```

You should receive a valid JSON-RPC initialize response.

## Smoke test helper

If present in your checkout:

```bash
./bin/hacktui-mcp-smoke
```

---

# Runtime Health and Diagnostic Commands

Start IEx:

```bash
iex -S mix
```

Then use the following commands.

## Global system health

```elixir
HacktuiHub.Health.status()
HacktuiAgent.Health.status()
HacktuiHub.QueryService.system_diagnostic()
```

## QueryService function inventory

```elixir
HacktuiHub.QueryService.__info__(:functions)
```

## Verify core runtime processes

```elixir
Process.whereis(HacktuiSensor.Forwarder)
Process.whereis(HacktuiHub.IngestService)
```

## Show sensor children

```elixir
DynamicSupervisor.which_children(HacktuiSensor.CollectorsSupervisor)
```

## Check network health

```elixir
HacktuiHub.QueryService.check_network_health()
```

## Verify `tshark` and `dumpcap` inside runtime

```elixir
System.find_executable("tshark")
System.find_executable("dumpcap")
```

---

# Network Collector Inspection

To inspect the running network collector in detail:

```elixir
network_pid =
(
  DynamicSupervisor.which_children(HacktuiSensor.CollectorsSupervisor)
  |> Enum.find_value(fn {_, pid, _, mods} ->
    if HacktuiSensor.Collectors.Network in mods, do: pid, else: nil
  end)
)
```

Show the PID:

```elixir
network_pid
```

Inspect collector state:

```elixir
:sys.get_state(network_pid)
```

This is useful for verifying:

- selected interface
- active port
- collector enablement
- collector error state
- startup timestamp
- resolved tshark path

---

# Live Telemetry Testing

## Clear the in-memory buffer

```elixir
HacktuiHub.QueryService.clear_buffer()
```

## Generate traffic from another terminal

```bash
ping -c 2 8.8.8.8
curl -I https://google.com
curl -I https://cloudflare.com
```

## Inspect recent observations

```elixir
HacktuiHub.QueryService.latest_observations()
```

## Get the live dashboard snapshot

```elixir
snapshot = HacktuiHub.QueryService.live_dashboard_snapshot(HacktuiStore.Repo, live_only: true)
```

## Summarize counts

```elixir
%{
  alerts: length(snapshot.alerts),
  cases: length(snapshot.cases),
  approvals: length(snapshot.approvals),
  observations: length(snapshot.observations)
}
```

## Filter network flows

```elixir
snapshot.observations
|> Enum.filter(&(Map.get(&1, :kind) == "network.flow"))
|> Enum.take(10)
```

## Filter security-relevant observations

```elixir
snapshot.observations
|> Enum.filter(&(Map.get(&1, :kind) in ["system.error", "journald.security", "network.flow"]))
|> Enum.take(20)
```

---

# Alert Workflow Testing

Load the command struct:

```elixir
alias HacktuiCore.Commands.CreateAlert
```

Create a high-severity alert through the runtime path:

```elixir
HacktuiHub.Runtime.create_alert(
  %CreateAlert{
    alert_id: "hermes-demo-" <> Integer.to_string(System.unique_integer([:positive])),
    title: "Beacon Detection",
    severity: :high,
    observation_refs: ["manual-net-1"],
    actor: "hermes"
  },
  repo: HacktuiStore.Repo,
  occurred_at: DateTime.utc_now(),
  event_id: "evt-hermes-demo-" <> Integer.to_string(System.unique_integer([:positive]))
)
```

Inspect the alert queue:

```elixir
HacktuiHub.QueryService.alert_queue(HacktuiStore.Repo)
```

Inspect the case board:

```elixir
HacktuiHub.QueryService.case_board(HacktuiStore.Repo)
```

## Correlation / deduplication check

Run the same pattern again with a different alert id:

```elixir
HacktuiHub.Runtime.create_alert(
  %CreateAlert{
    alert_id: "hermes-demo-repeat-" <> Integer.to_string(System.unique_integer([:positive])),
    title: "Beacon Detection",
    severity: :high,
    observation_refs: ["manual-net-1"],
    actor: "hermes"
  },
  repo: HacktuiStore.Repo,
  occurred_at: DateTime.utc_now(),
  event_id: "evt-hermes-demo-repeat-" <> Integer.to_string(System.unique_integer([:positive]))
)
```

Then inspect again:

```elixir
HacktuiHub.QueryService.alert_queue(HacktuiStore.Repo)
HacktuiHub.QueryService.case_board(HacktuiStore.Repo)
```

---

# Manual Observation Injection

If you want to inject a test observation directly:

```elixir
alias HacktuiCore.Commands.AcceptObservation

now = DateTime.utc_now() |> DateTime.truncate(:second)

obs = %AcceptObservation{
  observation_id: "manual-net-1",
  fingerprint: "manual-net-1",
  source: "iex.manual",
  kind: "network.flow",
  summary: "simulated attacker beacon",
  raw_message: "simulated attacker beacon",
  severity: "high",
  confidence: 0.95,
  payload: %{
    "src" => "10.0.0.99",
    "dst" => "185.199.108.153",
    "src_port" => 51515,
    "dst_port" => 443,
    "proto" => "TCP",
    "service" => "HTTPS",
    "site" => "malicious.test",
    "summary" => "simulated attacker beacon",
    "severity" => "high"
  },
  metadata: %{
    collector: :manual_test,
    severity: "high",
    occurred_at: DateTime.to_iso8601(now),
    observed_at: DateTime.to_iso8601(now),
    category: "network",
    tags: ["manual", "test", "beacon"]
  },
  observed_at: now,
  received_at: now,
  actor: "iex",
  envelope_version: 1
}

HacktuiSensor.Forwarder.accept_observation(obs)
```

Then inspect observations:

```elixir
HacktuiHub.QueryService.latest_observations(HacktuiStore.Repo, limit: 10)
```

---

# Clearing Demo State

## Clear the in-memory live buffer

```elixir
HacktuiHub.QueryService.clear_buffer()
```

## Remove persisted alerts and cases

```elixir
HacktuiStore.Repo.delete_all(HacktuiStore.Schema.CaseRecord)
HacktuiStore.Repo.delete_all(HacktuiStore.Schema.Alert)
```

## Optionally remove persisted observations

```elixir
HacktuiStore.Repo.delete_all(HacktuiStore.Schema.Observation)
HacktuiHub.QueryService.clear_buffer()
```

## Verify clean state

```elixir
HacktuiHub.QueryService.alert_queue(HacktuiStore.Repo)
HacktuiHub.QueryService.case_board(HacktuiStore.Repo)
HacktuiHub.QueryService.live_dashboard_snapshot(HacktuiStore.Repo, live_only: true)
```

---

# Testing the TUI While Live

## Terminal 1

Start the TUI:

```bash
mix hacktui.tui
```

## Terminal 2

Start IEx:

```bash
iex -S mix
```

Then check state:

```elixir
HacktuiHub.Health.status()
HacktuiAgent.Health.status()
HacktuiHub.QueryService.alert_queue(HacktuiStore.Repo)
HacktuiHub.QueryService.case_board(HacktuiStore.Repo)
HacktuiHub.QueryService.latest_observations()
```

Trigger a live alert while the TUI is open:

```elixir
alias HacktuiCore.Commands.CreateAlert

HacktuiHub.Runtime.create_alert(
  %CreateAlert{
    alert_id: "live-demo-" <> Integer.to_string(System.unique_integer([:positive])),
    title: "Hermes Beacon Detection",
    severity: :high,
    observation_refs: ["manual-net-1"],
    actor: "hermes"
  },
  repo: HacktuiStore.Repo,
  occurred_at: DateTime.utc_now(),
  event_id: "evt-live-demo-" <> Integer.to_string(System.unique_integer([:positive]))
)
```

---

# Running Tests

## Run all tests

```bash
mix test
```

## Run app-specific tests

```bash
mix test apps/hacktui_core/test
mix test apps/hacktui_hub/test
mix test apps/hacktui_agent/test
mix test apps/hacktui_sensor/test
mix test apps/hacktui_store/test
mix test apps/hacktui_tui/test
```

## Run a single test file

```bash
mix test apps/hacktui_hub/test/hacktui_hub_runtime_test.exs
```

## Run a single test line

```bash
mix test apps/hacktui_hub/test/hacktui_hub_runtime_test.exs:42
```

## Trace mode

```bash
mix test --trace
```

## Re-run only failures

```bash
mix test --failed
```

---

# Formatting and Compile Checks

Format everything:

```bash
mix format
```

Check formatting only:

```bash
mix format --check-formatted
```

Compile with warnings as errors:

```bash
mix compile --warnings-as-errors
```

---

# Security and Privacy Notes

Before publishing screenshots or logs:

- review environment variables
- verify no secrets are committed
- sanitize host identifiers when needed
- use privacy masking when sharing screenshots publicly
- review captured telemetry before publishing

Before pushing to GitHub, a quick sanity check:

```bash
git ls-files | grep env
git ls-files | grep key
git status
```

Expected result: no private `.env` files, no secret key files, and only intentional project files tracked.

---

# What Is Not Included

This repository does **not** include my private Hermes runtime or personal agent configuration.

It **does** include:

- the built-in MCP server
- Jido integration inside Ultraviolet
- bounded agent components used by the system itself

---

# Current Status

Ultraviolet is a **research prototype** exploring:

- terminal-native SOC workflows
- purple-team telemetry and replay
- bounded agent assistance
- AI-operable security infrastructure
- BEAM-native security system design

It is **not production ready**, but it already demonstrates a cohesive architecture for telemetry ingestion, alerting, case management, AI interoperability, and operator-driven security workflows.

---

# Quick Start

If you want the shortest possible path to a working system:

```bash
mix deps.get
mix compile
iex -S mix
```

Then in IEx:

```elixir
Application.ensure_all_started(:hacktui_store)
Application.ensure_all_started(:hacktui_hub)
Application.ensure_all_started(:hacktui_agent)
Application.ensure_all_started(:hacktui_sensor)
Application.ensure_all_started(:hacktui_tui)

HacktuiHub.Health.status()
HacktuiAgent.Health.status()
HacktuiHub.QueryService.check_network_health()
```

Then in another terminal:

```bash
mix hacktui.tui
```

And if you want to test MCP:

```bash
body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"demo","version":"0.1"}}}'
printf '%s\n' "$body" | ./bin/hacktui-mcp
```

---

# License

Ultraviolet is licensed under the **Apache License, Version 2.0**. See [`LICENSE`](LICENSE)
for the full terms and [`NOTICE`](NOTICE) for attribution requirements.

Apache-2.0 was chosen over a simpler permissive license because it includes an
explicit patent grant and contribution terms, which matter for security research
software that may be evaluated, extended, or redistributed by external parties.

Contributions are accepted under the same license; see [`CONTRIBUTING.md`](CONTRIBUTING.md).
