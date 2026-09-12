defmodule HacktuiHub.ReplayDedupeIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  case HacktuiTest.DbEnv.db_env() do
    :ok -> :ok
    {:skip, reason} -> @moduletag skip: reason
  end

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL

  alias HacktuiCore.Commands.AcceptObservation
  alias HacktuiCore.Events.ObservationAccepted
  alias HacktuiCore.Text
  alias HacktuiHub.{QueryService, Runtime}
  alias HacktuiHub.Replay.Runner
  alias HacktuiHub.TestSupport.Integration
  alias HacktuiStore.Repo
  alias HacktuiStore.Schema.AuditEvent

  setup_all do
    Integration.require_db_env!()
    Integration.start_repo!()
    Integration.migrate!()
    {:ok, _} = Application.ensure_all_started(:hacktui_hub)

    on_exit(fn ->
      Application.stop(:hacktui_hub)
      Integration.stop_repo!()
    end)

    :ok
  end

  setup do
    Integration.checkout!()
    Integration.cleanup!()
    :ok
  end

  # Replaying a fixture is the normal way to re-run a qualification. A second replay of the
  # same lines must not raise and must not write a second row per line: the observation is
  # the same observation, identified by (source, fingerprint).
  test "replaying case-1 twice yields one accepted-observation audit row per fixture line" do
    first = Runner.run_fixture!("case-1")
    assert [%ObservationAccepted{}, %ObservationAccepted{}] = first
    assert observation_audit_rows("replay-demo.case-1") == 2

    second = Runner.run_fixture!("case-1")
    assert [%ObservationAccepted{}, %ObservationAccepted{}] = second
    assert Enum.map(second, & &1.observation_id) == Enum.map(first, & &1.observation_id)

    assert observation_audit_rows("replay-demo.case-1") == 2
  end

  test "a duplicate observation is reported as :duplicate, distinct from :audited" do
    command = %AcceptObservation{
      observation_id: "obs-dedupe-1",
      source: "sensor.dedupe_test",
      kind: "process_signals",
      summary: "dedupe probe",
      raw_message: "dedupe probe line",
      severity: :low,
      confidence: 0.6,
      fingerprint: "fp-dedupe-1",
      payload: %{"message_queue_len" => 0},
      metadata: %{},
      actor: "hacktui_sensor",
      envelope_version: 1,
      received_at: ~U[2026-03-14 00:00:00Z]
    }

    assert {:ok, %{persistence: :audited}} = Runtime.accept_observation(command)
    assert {:ok, %{persistence: :duplicate}} = Runtime.accept_observation(command)
    assert observation_audit_rows("obs-dedupe-1") == 1
  end

  # Identity is (source, fingerprint), and ONLY that. A new id with the same
  # fingerprint is the same observation re-delivered (`:duplicate`); a repeated id with a
  # NEW fingerprint is a distinct observation wearing an id that is already taken -- a
  # caller defect -- and it is refused loudly, never reported as `:duplicate` and never
  # silently dropped. (An unscoped `on_conflict: :nothing` did exactly that, and every
  # collector's ids used to be VM counters that restart at 1.)
  test "same observation_id, different fingerprint: refused loudly, not a silent duplicate" do
    base = probe_command("obs-same-id", "fp-first")
    other = %AcceptObservation{base | fingerprint: "fp-second", raw_message: "other bytes"}

    assert {:ok, %{persistence: :audited}} = Runtime.accept_observation(base)

    assert {:error, {:audit_insert, %Postgrex.Error{postgres: %{code: :unique_violation}}}} =
             Runtime.accept_observation(other)

    [row] = Repo.all(from(a in AuditEvent, where: a.subject == "obs-same-id"))
    assert row.fingerprint == "fp-first"
    assert row.source == "sensor.dedupe_test"
  end

  test "different observation_id, same fingerprint: one row, the second is :duplicate" do
    first = probe_command("obs-id-a", "fp-shared")
    second = probe_command("obs-id-b", "fp-shared")

    assert {:ok, %{persistence: :audited}} = Runtime.accept_observation(first)
    assert {:ok, %{persistence: :duplicate, promoted: false}} = Runtime.accept_observation(second)

    assert observation_audit_rows("obs-id-") == 1

    assert Repo.one!(from(a in AuditEvent, where: a.fingerprint == "fp-shared")).subject ==
             "obs-id-a"
  end

  test "a non-observation audit_id collision is still an error, not a silent duplicate" do
    event = %HacktuiCore.Events.AuditRecorded{
      event_id: "evt-approve-1",
      audit_id: "audit-approve-1",
      actor:
        HacktuiCore.ActorRef.new!(id: "analyst-1", type: :human, role: :analyst, source: :tui),
      action: :approve_action,
      occurred_at: ~U[2026-03-14 00:00:00Z],
      result: :allowed,
      subject: "act-1"
    }

    assert {:ok, %{audit_outcome: :inserted}} = HacktuiStore.Audits.persist(Repo, event)

    assert {:error, :audit_insert, %Postgrex.Error{postgres: %{code: :unique_violation}}, _} =
             HacktuiStore.Audits.persist(Repo, event)

    assert Repo.one!(
             from(a in AuditEvent, where: a.audit_id == "audit-approve-1", select: count(a.id))
           ) == 1
  end

  defp probe_command(observation_id, fingerprint) do
    %AcceptObservation{
      observation_id: observation_id,
      source: "sensor.dedupe_test",
      kind: "process_signals",
      summary: "dedupe probe",
      raw_message: "dedupe probe line " <> observation_id,
      severity: :low,
      confidence: 0.6,
      fingerprint: fingerprint,
      payload: %{"message_queue_len" => 0},
      metadata: %{},
      actor: "hacktui_sensor",
      envelope_version: 1,
      received_at: ~U[2026-03-14 00:00:00Z]
    }
  end

  test "the raw-message digest and fingerprint survive to audit_events.metadata" do
    command = %AcceptObservation{
      observation_id: "obs-digest-1",
      source: "sensor.digest_test",
      kind: "process_signals",
      summary: "digest probe",
      raw_message: "digest probe line",
      severity: :low,
      confidence: 0.6,
      fingerprint: "fp-digest-1",
      payload: %{},
      metadata: %{},
      actor: "hacktui_sensor",
      envelope_version: 1,
      received_at: ~U[2026-03-14 00:00:00Z]
    }

    assert {:ok, %{persistence: :audited}} = Runtime.accept_observation(command)

    row = Repo.one!(from(a in AuditEvent, where: a.subject == "obs-digest-1"))

    assert Map.fetch!(row.metadata, "raw_message_sha256") ==
             Text.original_sha256("digest probe line")

    assert Map.fetch!(row.metadata, "fingerprint") == "fp-digest-1"
    refute Map.has_key?(row.metadata, "raw_message")
  end

  test "a marked observation's marking survives to alerts.marking and the alert queue" do
    marking = %{
      classification: "S",
      owner_producer: ["USA"],
      dissemination_controls: ["NOFORN"],
      source: :explicit
    }

    command =
      struct!(AcceptObservation, %{
        observation_id: "obs-marked-1",
        source: "sensor.marking_test",
        kind: "auth_failure",
        summary: "marked probe",
        raw_message: "marked probe line",
        severity: :high,
        confidence: 0.9,
        fingerprint: "fp-marked-1",
        marking: marking,
        payload: %{"severity" => "high"},
        metadata: %{},
        actor: "hacktui_sensor",
        envelope_version: 1,
        received_at: ~U[2026-03-14 00:00:00Z]
      })

    assert {:ok, %{promoted: true, alert: %{alert_id: alert_id}}} =
             Runtime.accept_observation(command)

    %{rows: [[stored]]} =
      SQL.query!(Repo, "SELECT marking FROM alerts WHERE alert_id = $1", [alert_id])

    assert stored == %{
             "classification" => "S",
             "owner_producer" => ["USA"],
             "dissemination_controls" => ["NOFORN"],
             "source" => "explicit"
           }

    row = Enum.find(QueryService.alert_queue(), &(&1.alert_id == alert_id))
    assert Map.fetch!(row, :marking) == stored

    # The promoting observation's identity is on the alert row, and the case a high
    # severity opens carries the same marking.
    assert row.fingerprint == "fp-marked-1"

    %{rows: [[case_marking, case_fingerprint]]} =
      SQL.query!(
        Repo,
        "SELECT marking, fingerprint FROM cases WHERE case_id = $1",
        ["case-alert-" <> alert_id]
      )

    assert case_marking == stored
    assert case_fingerprint == "fp-marked-1"
  end

  # Only this test's rows: the live sensor Forwarder writes its own observations into the
  # same database while the test runs, so a bare count is not a measurement.
  defp observation_audit_rows(subject_prefix) do
    pattern = subject_prefix <> "%"

    Repo.one(
      from(a in AuditEvent,
        where: a.action == "observation_accepted" and like(a.subject, ^pattern),
        select: count(a.id)
      )
    )
  end
end
