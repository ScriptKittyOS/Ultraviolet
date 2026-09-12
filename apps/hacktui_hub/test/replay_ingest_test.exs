defmodule HacktuiHub.ReplayIngestTest do
  use ExUnit.Case

  alias HacktuiCore.Aggregates.Alert
  alias HacktuiCore.Commands.AcceptObservation
  alias HacktuiCore.Events.{AlertCreated, ObservationAccepted}
  alias HacktuiHub.{IngestService, QueryService}
  alias HacktuiHub.Replay.Runner

  # Slice 39: this module asserts the in-memory (no-repo) read path, so it ESTABLISHES that
  # state instead of inheriting whatever the previous module left behind. Measured at seed 0
  # on origin/main = 9170a88: an earlier integration module left :start_repo true, the hub
  # queried a repo that was not there, and `snapshot.observations` came back [].
  setup_all do
    HacktuiTest.DbEnv.set_start_repo!(false)

    if Process.whereis(HacktuiHub.Supervisor), do: Application.stop(:hacktui_hub)
    if Process.whereis(HacktuiStore.Supervisor), do: Application.stop(:hacktui_store)

    {:ok, _} = Application.ensure_all_started(:hacktui_hub)
    refute Process.whereis(HacktuiStore.Repo), "this module asserts the no-repo path"

    on_exit(fn -> HacktuiTest.DbEnv.restore_start_repo!() end)
    :ok
  end

  test "accept_observation assigns ingest defaults and exposes live snapshot observations" do
    IngestService.reset_recent_observations()

    command = %AcceptObservation{
      observation_id: "obs-live-test",
      envelope_version: 1,
      summary: "Replay ingest smoke observation",
      raw_message: "replay ingest smoke observation",
      severity: "medium",
      confidence: 0.75,
      source: "sensor.process_signals",
      kind: "process_signals",
      payload: %{"message_queue_len" => 0, "reductions" => 1},
      metadata: %{collector: :process_signals, path: :live},
      observed_at: ~U[2026-03-14 00:00:00Z],
      received_at: ~U[2026-03-14 00:00:00Z],
      actor: "hacktui_sensor"
    }

    assert {:ok, %ObservationAccepted{} = accepted} =
             IngestService.accept_observation(command, [])

    assert accepted.kind == "process_signals"
    assert accepted.payload["message_queue_len"] == 0

    snapshot = QueryService.live_dashboard_snapshot()
    assert snapshot.observations != []
    assert Enum.any?(snapshot.observations, &(&1.kind == "process_signals"))
  end

  test "case-1 replay produces accepted observations" do
    results = Runner.run_fixture!("case-1")

    assert length(results) == 2

    assert [%ObservationAccepted{} = first, %ObservationAccepted{} = second] = results

    assert Enum.map(results, & &1.observation_id) == [first.observation_id, second.observation_id]

    assert Enum.map(results, & &1.event_id) == [
             "replay-demo.case-1-alert_observed-1",
             "replay-demo.case-1-alert_observed-2"
           ]

    assert Enum.map(results, & &1.accepted_at) == [
             ~U[2026-03-07 13:00:00Z],
             ~U[2026-03-07 13:00:10Z]
           ]

    assert %ObservationAccepted{
             source: "demo.case-1",
             kind: "alert_observed",
             payload: %{"alert_id" => "alert-1", "indicator" => "10.0.0.4", "severity" => "high"},
             metadata: %{"fixture" => "case-1", "sequence" => 1}
           } = first

    assert %ObservationAccepted{
             source: "demo.case-1",
             kind: "alert_observed",
             payload: %{
               "alert_id" => "alert-2",
               "indicator" => "malicious.example",
               "severity" => "medium"
             },
             metadata: %{"fixture" => "case-1", "sequence" => 2}
           } = second
  end

  test "case-1 accepted observations derive alert-like internal results" do
    accepted = Runner.run_fixture!("case-1")

    derived = Runner.derive_alerts!(accepted)

    assert [
             {%Alert{} = first_alert, %AlertCreated{} = first_event},
             {%Alert{} = second_alert, %AlertCreated{} = second_event}
           ] = derived

    assert {first_alert.alert_id, first_alert.severity, first_alert.observation_refs} ==
             {"alert-1", :high, [hd(accepted).observation_id]}

    assert {first_event.alert_id, first_event.title, first_event.severity} ==
             {"alert-1", "Replay-derived alert for 10.0.0.4", :high}

    assert {second_alert.alert_id, second_alert.severity, second_alert.observation_refs} ==
             {"alert-2", :medium, [List.last(accepted).observation_id]}

    assert {second_event.alert_id, second_event.title, second_event.severity} ==
             {"alert-2", "Replay-derived alert for malicious.example", :medium}
  end
end
