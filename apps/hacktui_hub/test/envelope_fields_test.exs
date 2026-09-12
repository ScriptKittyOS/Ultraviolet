defmodule HacktuiHub.EnvelopeFieldsTest do
  @moduledoc """
  Slice 40, the parts that need no database: the marking an observation inherits, the
  digest it carries, and what the runtime reports when the store says "already have it".
  """
  use ExUnit.Case, async: false

  alias HacktuiCore.Commands.AcceptObservation
  alias HacktuiCore.Events.ObservationAccepted
  alias HacktuiCore.Text
  alias HacktuiHub.{IngestService, Runtime}

  defmodule DuplicateRepo do
    @moduledoc "A store that already holds every observation: insert_all inserts 0 rows."
    @behaviour HacktuiStore.RepoBehaviour

    @impl true
    def transaction(multi) do
      multi
      |> Ecto.Multi.to_list()
      |> Enum.reduce_while({:ok, %{}}, fn
        {name, {:run, fun}}, {:ok, acc} ->
          case fun.(__MODULE__, acc) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
            {:error, reason} -> {:halt, {:error, name, reason, acc}}
          end

        {name, {:insert_all, _schema, _rows, _opts}}, {:ok, acc} ->
          {:cont, {:ok, Map.put(acc, name, {0, nil})}}

        {name, op}, {:ok, acc} ->
          {:cont, {:ok, Map.put(acc, name, op)}}
      end)
    end

    @impl true
    def all(_query), do: []
    @impl true
    def get_by(_schema, _clauses), do: nil
    @impl true
    def update(changeset), do: {:ok, Ecto.Changeset.apply_changes(changeset)}
  end

  defp command(overrides) do
    now = ~U[2026-03-14 00:00:00Z]

    struct!(
      AcceptObservation,
      Map.merge(
        %{
          observation_id: "obs-#{System.unique_integer([:positive])}",
          fingerprint: "fp-#{System.unique_integer([:positive])}",
          envelope_version: 2,
          source: "sensor.network",
          kind: "network.flow",
          summary: "flow",
          raw_message: "TCP 10.0.0.4:51000 -> 93.184.216.34:443",
          severity: :low,
          confidence: 0.6,
          payload: %{"summary" => "flow", "severity" => "low"},
          metadata: %{},
          observed_at: now,
          received_at: now,
          actor: "sensor"
        },
        overrides
      )
    )
  end

  describe "marking inheritance at ingest" do
    test "an unmarked observation inherits the enclave marking" do
      assert {:ok, %ObservationAccepted{marking: marking}} =
               IngestService.accept_observation(command(%{}), [])

      assert marking == HacktuiCore.Marking.enclave()
      assert marking.classification == "U"
      assert marking.source == :enclave_default
    end

    test "a marked observation keeps its marking, normalised from string keys" do
      given = %{"classification" => "S", "dissemination_controls" => ["NOFORN"]}

      assert {:ok, %ObservationAccepted{marking: marking}} =
               IngestService.accept_observation(command(%{marking: given}), [])

      assert marking == %{
               classification: "S",
               owner_producer: [],
               dissemination_controls: ["NOFORN"],
               source: :explicit
             }
    end

    test "a malformed marking is refused, not stored" do
      assert_raise ArgumentError, ~r/classification must be one of U, C, S, TS/, fn ->
        IngestService.accept_observation(command(%{marking: %{classification: "SECRET"}}), [])
      end
    end
  end

  describe "the evidence commitment" do
    test "the event carries the full sha256 of the raw message and not the message" do
      raw = "TCP 10.0.0.4:51000 -> 93.184.216.34:443"

      assert {:ok, %ObservationAccepted{} = accepted} =
               IngestService.accept_observation(command(%{raw_message: raw}), [])

      assert accepted.raw_message_sha256 == Text.original_sha256(raw)
      assert String.length(accepted.raw_message_sha256) == 64
      refute Map.has_key?(accepted, :raw_message)
    end
  end

  # Runtime only persists when the repo module is loaded AND registered as a process.
  # Unregister BEFORE the kill: Process.exit/2 is asynchronous, and a later test registering
  # the same name must not race the old pid's death.
  defp register_repo(module) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(pid, module)

    on_exit(fn ->
      if Process.whereis(module) == pid, do: Process.unregister(module)
      Process.exit(pid, :kill)
    end)

    :ok
  end

  describe "provenance on the rows an observation promotes" do
    setup do
      register_repo(HacktuiHub.TestSupport.FakeTransactionRepo)
    end

    test "the alert insert and the case insert carry the observation's marking and fingerprint" do
      marking = %{
        classification: "C",
        owner_producer: [],
        dissemination_controls: [],
        source: :explicit
      }

      high =
        command(%{
          fingerprint: "fp-prov-1",
          marking: marking,
          severity: :high,
          # Promotes by severity alone: a summary matching threat intel takes the
          # threat-alert branch, which needs an :occurred_at this caller does not pass
          # (pre-existing on the base; recorded as a gap by this slice, not exercised here).
          payload: %{"summary" => "unexpected listener", "severity" => "high"}
        })

      assert {:ok, result} =
               Runtime.accept_observation(high, repo: HacktuiHub.TestSupport.FakeTransactionRepo)

      assert result.promoted
      assert {:insert, alert_changeset, _} = result.alert_persistence.alert_insert
      assert alert_changeset.changes.marking == marking
      assert alert_changeset.changes.fingerprint == "fp-prov-1"

      assert {:insert, case_changeset, _} = result.case_result.persistence.case_insert
      assert case_changeset.changes.marking == marking
      assert case_changeset.changes.fingerprint == "fp-prov-1"
    end
  end

  describe "a duplicate observation" do
    setup do
      register_repo(DuplicateRepo)
    end

    test "is reported as :duplicate and is not promoted, even at high severity" do
      high =
        command(%{severity: :high, payload: %{"summary" => "mimikatz", "severity" => "high"}})

      assert {:ok, result} = Runtime.accept_observation(high, repo: DuplicateRepo)
      assert result.persistence == :duplicate
      assert result.audit_persistence.audit_outcome == :duplicate
      refute result.promoted
      assert result.alert == nil
    end
  end
end
