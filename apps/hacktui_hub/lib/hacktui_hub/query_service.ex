defmodule HacktuiHub.QueryService do
  @moduledoc """
  Query adapter layer that exposes store read models to outer interfaces.
  Ensures live telemetry variety and proper timestamp sorting for the TUI.

  This version keeps the alert queue simple and authoritative:
    Runtime.create_alert/2 -> alerts table -> QueryService.alert_queue/1

  No audit-event reconstruction, no seeded fallback, no hidden rescue path that
  turns real alerts into an empty queue.
  """

  import Ecto.Query

  require Logger

  alias HacktuiStore.{ReadModels, Repo}
  alias HacktuiStore.Schema.{ActionRequest, Alert, AuditEvent, CaseRecord}

  @spec alert_queue(module()) :: list()
  def alert_queue(repo \\ Repo) do
    repo
    |> safe_all_query(
      from(alert in Alert,
        order_by: [desc: alert.inserted_at]
      )
    )
    |> Enum.map(&normalize_alert/1)
    |> suppress_seeded_when_real_present()
  end

  @spec case_board(module()) :: list()
  def case_board(repo \\ Repo) do
    repo
    |> safe_all_query(
      from(case_record in CaseRecord,
        order_by: [desc: case_record.updated_at]
      )
    )
    |> Enum.map(&normalize_case/1)
    |> suppress_seeded_when_real_present()
  end

  @spec approval_inbox(module()) :: list()
  def approval_inbox(repo \\ Repo) do
    repo
    |> safe_all_query(
      from(action_request in ActionRequest,
        where: action_request.approval_status == "pending_approval",
        order_by: [desc: action_request.inserted_at]
      )
    )
    |> Enum.map(&normalize_approval/1)
  end

  @spec audit_events(module()) :: list()
  def audit_events(repo \\ Repo) do
    repo
    |> safe_all_query(
      from(audit_event in AuditEvent,
        order_by: [desc: audit_event.occurred_at]
      )
    )
  end

  @spec pending_action_for_case(module(), String.t()) :: struct() | nil
  def pending_action_for_case(repo \\ Repo, case_id) do
    repo.one(ReadModels.pending_action_for_case_query(case_id))
  end

  @doc """
  Performs a comprehensive system check for the operator.
  """
  def system_diagnostic do
    recent = HacktuiHub.IngestService.recent_observations()

    %{
      node: node(),
      cluster_size: length(Node.list()) + 1,
      db_status: check_db_status(),
      buffer_load: "#{length(recent)}/100",
      telemetry_breakdown: Enum.frequencies_by(recent, & &1.kind),
      alert_backlog: length(alert_queue()),
      latest_sample: latest_observations(limit: 3)
    }
  end

  @doc """
  Specific health check for the network collector.
  """
  def check_network_health do
    recent = HacktuiHub.IngestService.recent_observations()
    errors = Enum.filter(recent, &(&1.kind == "system.error"))
    flows = Enum.filter(recent, &(&1.kind == "network.flow"))

    %{
      status: if(length(flows) > 0, do: :active, else: :idle),
      flow_count: length(flows),
      last_error:
        List.first(errors)
        |> then(fn e -> if e, do: get_in(e.payload, ["summary"]), else: nil end),
      tshark_present?: !is_nil(System.find_executable("tshark")),
      dumpcap_path: System.find_executable("dumpcap"),
      collector_process: network_collector_pid()
    }
  end

  @doc """
  Clears the live ingest buffer. Useful for resetting the TUI view during testing.
  """
  def clear_buffer do
    HacktuiHub.IngestService.reset_recent_observations()
  end

  @doc """
  Injects simulated network traffic to verify UI rendering.
  """
  def simulate_network_traffic do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    payload = %{
      "src" => "192.168.1.45",
      "dst" => "104.21.23.210",
      "src_port" => 51515,
      "dst_port" => 443,
      "proto" => "TCP",
      "service" => "HTTPS",
      "site" => "api.example.test",
      "summary" => "[TCP] 192.168.1.45 -> 104.21.23.210 | HTTPS GET /api/v1/auth",
      "severity" => "low"
    }

    command = %HacktuiCore.Commands.AcceptObservation{
      observation_id: "sim-net-#{System.unique_integer([:positive])}",
      fingerprint: "sim-net-#{System.unique_integer([:positive])}",
      source: "sensor.network.sim",
      kind: "network.flow",
      summary: payload["summary"],
      raw_message: payload["summary"],
      severity: :low,
      confidence: 0.6,
      payload: payload,
      metadata: %{
        collector: :packet_capture,
        severity: "low",
        occurred_at: DateTime.to_iso8601(now),
        observed_at: DateTime.to_iso8601(now),
        category: "network",
        tags: ["sim", "network"]
      },
      observed_at: now,
      received_at: now,
      actor: "iex_shell",
      envelope_version: 1
    }

    HacktuiHub.Runtime.accept_observation(command, [])
  end

  @doc """
  Manually triggers an alert through the full runtime path.
  """
  def simulate_alert(title \\ "Manual Test Alert", severity \\ :high) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    severity_atom = if is_binary(severity), do: String.to_atom(severity), else: severity

    command = %HacktuiCore.Commands.CreateAlert{
      alert_id: "alert-manual-#{System.unique_integer([:positive])}",
      title: title,
      severity: severity_atom,
      observation_refs: [],
      actor: "iex_shell"
    }

    HacktuiHub.Runtime.create_alert(
      command,
      repo: Repo,
      occurred_at: now,
      event_id: "evt-manual-#{System.unique_integer([:positive])}"
    )
  end

  @spec latest_observations(keyword()) :: list()
  def latest_observations(opts) when is_list(opts), do: latest_observations(Repo, opts)

  @spec latest_observations(module(), keyword()) :: list()
  def latest_observations(repo, opts) do
    limit = Keyword.get(opts, :limit, 50)

    live_observations =
      try do
        HacktuiHub.IngestService.recent_observations()
        |> Enum.map(&normalize_observation_event/1)
      rescue
        _ -> []
      end

    all_observations =
      if length(live_observations) < limit do
        historical =
          audit_events(repo)
          |> Enum.filter(&observation_event?/1)
          |> Enum.map(&normalize_observation_event/1)

        Enum.uniq_by(live_observations ++ historical, fn obs ->
          Map.get(obs.metadata || %{}, :observation_id) ||
            Map.get(obs.metadata || %{}, "observation_id") ||
            "#{obs.kind}-#{inspect(obs.accepted_at)}"
        end)
      else
        live_observations
      end

    all_observations
    |> Enum.sort_by(
      fn obs ->
        {
          DateTime.to_unix(event_time(obs), :microsecond),
          obs.kind,
          Map.get(obs.metadata || %{}, :observation_id, "")
        }
      end,
      :desc
    )
    |> Enum.take(limit)
  end

  def latest_observations, do: latest_observations(Repo, [])

  @spec case_timeline(module(), String.t()) :: list()
  def case_timeline(repo \\ Repo, case_id) do
    safe_all_query(repo, ReadModels.case_timeline_query(case_id))
  end

  @spec investigation_context(module(), String.t()) :: map()
  def investigation_context(repo \\ Repo, case_id) do
    %{
      alerts: alert_queue(repo),
      timeline: case_timeline(repo, case_id) |> Enum.map(&normalize_timeline_entry/1)
    }
  end

  @spec live_dashboard_snapshot(keyword()) :: map()
  def live_dashboard_snapshot(opts) when is_list(opts), do: live_dashboard_snapshot(Repo, opts)

  @spec live_dashboard_snapshot(module(), keyword()) :: map()
  def live_dashboard_snapshot(repo, opts) do
    alert_limit = Keyword.get(opts, :alert_limit, 18)
    case_limit = Keyword.get(opts, :case_limit, 8)
    approval_limit = Keyword.get(opts, :approval_limit, 8)
    observation_limit = Keyword.get(opts, :observation_limit, 50)

    clear_query_failure()

    snapshot = %{
      alerts: alert_queue(repo) |> Enum.take(alert_limit),
      cases: case_board(repo) |> Enum.take(case_limit),
      approvals: approval_inbox(repo) |> Enum.take(approval_limit),
      observations: latest_observations(repo, limit: observation_limit)
    }

    Map.put(snapshot, :degraded, last_query_failure())
  end

  def live_dashboard_snapshot, do: live_dashboard_snapshot(Repo, [])

  @doc """
  MCP compatibility helper for recent sensor-facing telemetry.
  """
  @spec sensor_logs(module()) :: list()
  def sensor_logs(repo \\ Repo) do
    latest_observations(repo, limit: 50)
  end

  @doc """
  MCP compatibility helper for recent Jido / agent-related responses.

  Filters the recent observation stream down to entries that look agent-related.
  If there are no explicit Jido observations yet, this safely returns an empty list.
  """
  @spec jido_responses(module()) :: list()
  def jido_responses(repo \\ Repo) do
    latest_observations(repo, limit: 100)
    |> Enum.filter(fn obs ->
      kind =
        obs
        |> Map.get(:kind, "")
        |> to_string()
        |> String.downcase()

      metadata = Map.get(obs, :metadata, %{}) || %{}

      collector =
        (Map.get(metadata, :collector) || Map.get(metadata, "collector") || "")
        |> to_string()
        |> String.downcase()

      payload = Map.get(obs, :payload, %{}) || %{}

      summary =
        (Map.get(payload, "summary") || Map.get(payload, :summary) || "")
        |> to_string()
        |> String.downcase()

      String.contains?(kind, "jido") or
        String.contains?(kind, "agent") or
        String.contains?(collector, "jido") or
        String.contains?(collector, "agent") or
        String.contains?(summary, "jido") or
        String.contains?(summary, "agent")
    end)
  end

  # --- Helpers ---

  defp check_db_status do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> :connected
      _ -> :disconnected
    end
  rescue
    _ -> :disconnected
  end

  defp network_collector_pid do
    try do
      DynamicSupervisor.which_children(HacktuiSensor.CollectorsSupervisor)
      |> Enum.find_value(fn
        {_, pid, _, mods} when is_pid(pid) and is_list(mods) ->
          if HacktuiSensor.Collectors.Network in mods, do: pid, else: nil

        _ ->
          nil
      end)
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp observation_event?(%{kind: k}) when is_binary(k) do
    String.contains?(k, ["journald", "network", "system", "heartbeat", "error"])
  end

  defp observation_event?(%{entry_type: entry_type}) when is_binary(entry_type) do
    String.contains?(entry_type, ["observation", "network", "journald", "system", "error"])
  end

  defp observation_event?(_), do: false

  defp normalize_alert(%Alert{} = alert) do
    metadata = alert.metadata || %{}

    %{
      alert_id: alert.alert_id,
      title: alert.title,
      severity: normalize_severity(alert.severity),
      state: normalize_state(alert.state),
      disposition: alert.disposition,
      marking: alert.marking,
      fingerprint: alert.fingerprint,
      metadata: metadata,
      indicators:
        normalize_indicators(
          Map.get(metadata, :indicators) ||
            Map.get(metadata, "indicators")
        )
    }
  end

  defp normalize_alert(%{metadata: metadata} = alert) do
    metadata = metadata || %{}

    %{
      alert_id: Map.get(alert, :alert_id),
      title: Map.get(alert, :title),
      severity: normalize_severity(Map.get(alert, :severity)),
      state: normalize_state(Map.get(alert, :state)),
      disposition: Map.get(alert, :disposition),
      marking: Map.get(alert, :marking),
      fingerprint: Map.get(alert, :fingerprint),
      metadata: metadata,
      indicators:
        normalize_indicators(
          Map.get(alert, :indicators) ||
            Map.get(metadata, :indicators) ||
            Map.get(metadata, "indicators")
        )
    }
  end

  defp normalize_case(%CaseRecord{} = case_record) do
    %{
      case_id: case_record.case_id,
      title: case_record.title,
      status: case_record.status,
      marking: case_record.marking,
      fingerprint: case_record.fingerprint,
      metadata: case_record.metadata || %{},
      assigned_to: case_record.assigned_to || "unassigned"
    }
  end

  defp normalize_case(case_record) do
    %{
      case_id: Map.get(case_record, :case_id),
      title: Map.get(case_record, :title),
      status: Map.get(case_record, :status),
      marking: Map.get(case_record, :marking),
      fingerprint: Map.get(case_record, :fingerprint),
      metadata: Map.get(case_record, :metadata) || %{},
      assigned_to: Map.get(case_record, :assigned_to) || "unassigned"
    }
  end

  defp normalize_approval(%ActionRequest{} = approval) do
    %{
      action_request_id: approval.action_request_id,
      case_id: approval.case_id,
      approval_status: approval.approval_status,
      target: approval.target || "unknown"
    }
  end

  defp normalize_approval(approval) do
    %{
      action_request_id: Map.get(approval, :action_request_id),
      case_id: Map.get(approval, :case_id),
      approval_status: Map.get(approval, :approval_status) || Map.get(approval, :status),
      target: Map.get(approval, :target) || "unknown"
    }
  end

  defp normalize_timeline_entry(%{metadata: metadata} = entry) do
    metadata = metadata || %{}

    %{
      entry_type: Map.get(entry, :entry_type),
      summary: Map.get(entry, :summary),
      indicators:
        normalize_indicators(
          Map.get(entry, :indicators) ||
            Map.get(metadata, :indicators) ||
            Map.get(metadata, "indicators")
        ),
      recommendation: Map.get(metadata, :recommendation) || Map.get(metadata, "recommendation")
    }
  end

  defp normalize_indicators(nil), do: []
  defp normalize_indicators(indicators) when is_list(indicators), do: indicators
  defp normalize_indicators(indicator), do: [indicator]

  defp normalize_observation_event(event) do
    metadata = Map.get(event, :metadata, %{}) || %{}

    enriched_metadata =
      metadata
      |> Map.put_new(:severity, metadata["severity"] || "info")
      |> Map.put_new(:collector, metadata["collector"] || "unknown")
      |> Map.put_new(
        :observation_id,
        Map.get(event, :observation_id) ||
          Map.get(metadata, :observation_id) ||
          Map.get(metadata, "observation_id")
      )

    %{
      kind: Map.get(event, :kind) || Map.get(event, :entry_type) || "unknown",
      payload: Map.get(event, :payload, %{}),
      metadata: enriched_metadata,
      accepted_at: Map.get(event, :accepted_at) || event_time(event)
    }
  end

  defp suppress_seeded_when_real_present(rows) do
    real_rows =
      Enum.reject(rows, fn row ->
        metadata = Map.get(row, :metadata) || %{}
        Map.get(metadata, :seeded) == true or Map.get(metadata, "seeded") == true
      end)

    if real_rows != [] do
      real_rows
    else
      rows
    end
  end

  defp normalize_severity(nil), do: "info"

  defp normalize_severity(severity) when is_atom(severity),
    do: severity |> Atom.to_string() |> String.downcase()

  defp normalize_severity(severity), do: severity |> to_string() |> String.downcase()

  defp normalize_state(nil), do: "open"

  defp normalize_state(state) when is_atom(state),
    do: state |> Atom.to_string() |> String.downcase()

  defp normalize_state(state), do: state |> to_string() |> String.downcase()

  # Returns {:ok, rows} | {:error, reason}. An operator must be able to tell
  # "no alerts" from "cannot read alerts"; a security console that renders those
  # identically is worse than one that shows nothing.
  @spec query_all(module(), Ecto.Query.t()) :: {:ok, list()} | {:error, term()}
  defp query_all(repo, query) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :all, 1) do
      {:ok, repo.all(query)}
    else
      {:error, :repo_unavailable}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # List-returning wrapper for callers that cannot handle a tuple. Unlike the previous
  # silent rescue, a failure is logged and recorded for the dashboard's DEGRADED banner.
  defp safe_all_query(repo, query) do
    case query_all(repo, query) do
      {:ok, rows} ->
        rows

      {:error, reason} ->
        Logger.warning("[hacktui_hub] query failed: #{inspect(reason)}")
        record_query_failure(reason)
        []
    end
  end

  @failure_key {__MODULE__, :last_query_failure}

  defp record_query_failure(reason) do
    Process.put(@failure_key, %{reason: reason, at: DateTime.utc_now()})
    :ok
  end

  @doc """
  The most recent read-model query failure in this process, or nil.

  Used by the dashboard to render a DEGRADED banner instead of an empty queue.
  """
  @spec last_query_failure() :: map() | nil
  def last_query_failure, do: Process.get(@failure_key)

  defp clear_query_failure, do: Process.delete(@failure_key)

  defp event_time(%{metadata: metadata}) when is_map(metadata) do
    ts = Map.get(metadata, :occurred_at) || Map.get(metadata, "occurred_at")

    if is_binary(ts) do
      case DateTime.from_iso8601(ts) do
        {:ok, dt, _} -> dt
        _ -> DateTime.utc_now()
      end
    else
      DateTime.utc_now()
    end
  end

  defp event_time(%{occurred_at: %DateTime{} = dt}), do: dt
  defp event_time(%{accepted_at: %DateTime{} = dt}), do: dt
  defp event_time(_), do: DateTime.utc_now()
end
