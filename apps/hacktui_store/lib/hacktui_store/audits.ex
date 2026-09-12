defmodule HacktuiStore.Audits do
  @moduledoc """
  Ecto persistence flows for audit events.

  An observation that arrives twice -- a replayed fixture, a re-forwarded batch -- is one
  observation. The insert is `ON CONFLICT DO NOTHING` scoped to the identity index ONLY
  (`(source, fingerprint)` on observation rows, the partial index below), and the
  transaction's `:audit_outcome` step reports `:inserted` or `:duplicate` so the caller can
  say which. A collision on `audit_id` is NOT a duplicate and raises, as it always did: an
  unscoped `ON CONFLICT DO NOTHING` was measured (round 1) to report a distinct observation
  whose id merely repeated -- collector counters restart with the VM -- as `:duplicate`,
  silently, and to turn a repeated caller-supplied `audit_id` into a write that never
  happened. `insert_all/3` rather than `insert/2` because only its row count can tell an
  insert from a skip: `insert/2` with `on_conflict: :nothing` returns the same struct either way.
  """

  alias Ecto.Multi
  alias HacktuiCore.Events.AuditRecorded
  alias HacktuiStore.Schema.{AuditEvent, MarkingField}

  @type outcome :: :inserted | :duplicate

  # Must name the partial index's columns AND predicate, or Postgres cannot pick it as the
  # arbiter. Kept in step with the migration.
  @identity_index {:unsafe_fragment,
                   "(source, fingerprint) WHERE action = 'observation_accepted' AND fingerprint IS NOT NULL"}

  @doc "The conflict target the insert is scoped to, for tests that pin it."
  @spec identity_index() :: {:unsafe_fragment, String.t()}
  def identity_index, do: @identity_index

  @spec persist(module(), AuditRecorded.t()) :: HacktuiStore.transaction_result()
  def persist(repo, %AuditRecorded{} = event) do
    case Ecto.Changeset.apply_action(audit_changeset(event), :insert) do
      {:ok, %AuditEvent{} = row} ->
        Multi.new()
        |> Multi.insert_all(:audit_insert, AuditEvent, [insert_row(row)],
          on_conflict: :nothing,
          conflict_target: @identity_index
        )
        |> Multi.run(:audit_outcome, fn _repo, %{audit_insert: {count, _returned}} ->
          {:ok, outcome(count)}
        end)
        |> run_transaction(repo)

      {:error, changeset} ->
        {:error, :audit_insert, changeset, %{}}
    end
  end

  # `insert_all/3` has no changeset to carry a `unique_constraint/2` into, so a violation
  # outside the scoped target -- an `audit_id` that already exists -- surfaces as a raised
  # adapter error rather than the `{:error, :audit_insert, …}` the `insert/2` version
  # returned. Translate exactly that case back, so the caller sees a refused write; every
  # other server error (schema drift, privileges, a full disk) still propagates and is
  # reported as an outage, as before.
  defp run_transaction(multi, repo) do
    repo.transaction(multi)
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: :unique_violation}} ->
          {:error, :audit_insert, error, %{}}

        _other ->
          reraise error, __STACKTRACE__
      end
  end

  defp outcome(1), do: :inserted
  defp outcome(0), do: :duplicate

  # insert_all does not run autogenerate, so the timestamps are set here; every other
  # value has already been cast and validated by the changeset.
  defp insert_row(%AuditEvent{} = row) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row
    |> Map.from_struct()
    |> Map.take(AuditEvent.__schema__(:fields))
    |> Map.put(:inserted_at, now)
    |> Map.put(:updated_at, now)
  end

  defp audit_changeset(%AuditRecorded{} = event) do
    AuditEvent.changeset(%AuditEvent{}, %{
      id: Ecto.UUID.generate(),
      audit_id: event.audit_id,
      action: Atom.to_string(event.action),
      result: Atom.to_string(event.result),
      actor_id: event.actor.id,
      subject: event.subject,
      occurred_at: event.occurred_at,
      source: event.source,
      fingerprint: event.fingerprint,
      marking: MarkingField.for_write(event.marking),
      metadata:
        Map.merge(
          %{
            event_id: event.event_id,
            subject: event.subject,
            action: event.action,
            result: event.result
          },
          event.metadata || %{}
        )
    })
  end
end
