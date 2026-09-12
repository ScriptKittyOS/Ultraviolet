defmodule HacktuiStore.AuditsErrorsTest do
  # Only an audit_id collision is translated into a refused write; every other server
  # error propagates so the runtime reports an outage, as it did before insert_all.
  use ExUnit.Case, async: true

  alias HacktuiCore.ActorRef
  alias HacktuiCore.Events.AuditRecorded
  alias HacktuiStore.Audits

  defmodule RaisingRepo do
    def transaction(_multi) do
      raise Process.get(:raise_with)
    end
  end

  defp event do
    %AuditRecorded{
      event_id: "evt-1",
      audit_id: "audit-1",
      actor: ActorRef.new!(id: "analyst-1", type: :human, role: :analyst, source: :tui),
      action: :approve_action,
      occurred_at: ~U[2026-03-07 00:00:00Z],
      result: :allowed,
      subject: "act-1"
    }
  end

  test "a unique violation is a refused write" do
    Process.put(:raise_with, %Postgrex.Error{
      postgres: %{code: :unique_violation, message: "dup", severity: "ERROR", pg_code: "23505"}
    })

    assert {:error, :audit_insert, %Postgrex.Error{}, %{}} = Audits.persist(RaisingRepo, event())
  end

  test "any other server error propagates" do
    Process.put(:raise_with, %Postgrex.Error{
      postgres: %{code: :undefined_column, message: "drift", severity: "ERROR", pg_code: "42703"}
    })

    assert_raise Postgrex.Error, fn -> Audits.persist(RaisingRepo, event()) end
  end
end
