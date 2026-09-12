defmodule HacktuiStore.MarkingFieldTest do
  # Slice 40: a row is written with a well-formed marking or not at all.
  use ExUnit.Case, async: true

  alias HacktuiStore.Schema.{Alert, AuditEvent, CaseRecord, MarkingField}

  @alert %{alert_id: "a", title: "t", severity: "low", state: "open", disposition: "unknown"}
  @case %{case_id: "c", title: "t", status: "open"}
  @audit %{audit_id: "x", action: "a", result: "r", occurred_at: ~U[2026-03-07 00:00:00Z]}
  @good %{classification: "C", owner_producer: [], dissemination_controls: [], source: :explicit}

  test "a well-formed marking is accepted on all three schemas" do
    assert Alert.changeset(%Alert{}, Map.put(@alert, :marking, @good)).valid?
    assert CaseRecord.changeset(%CaseRecord{}, Map.put(@case, :marking, @good)).valid?
    assert AuditEvent.changeset(%AuditEvent{}, Map.put(@audit, :marking, @good)).valid?
  end

  test "an absent marking is refused" do
    refute Alert.changeset(%Alert{}, @alert).valid?
    refute CaseRecord.changeset(%CaseRecord{}, @case).valid?
    refute AuditEvent.changeset(%AuditEvent{}, @audit).valid?
  end

  test "an empty map is not a marking" do
    changeset = Alert.changeset(%Alert{}, Map.put(@alert, :marking, %{}))
    refute changeset.valid?

    assert {"marking classification must be one of U, C, S, TS, got: nil", _} =
             changeset.errors[:marking]
  end

  test "an unrecognised classification is refused" do
    changeset = Alert.changeset(%Alert{}, Map.put(@alert, :marking, %{classification: "SECRET"}))
    refute changeset.valid?
    assert {message, _} = changeset.errors[:marking]
    assert message =~ "must be one of U, C, S, TS"
  end

  test "for_write/1 supplies the enclave marking when none was given" do
    assert MarkingField.for_write(nil) == HacktuiCore.Marking.enclave()
    assert MarkingField.for_write(%{"classification" => "TS"}).classification == "TS"
  end
end
