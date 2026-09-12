defmodule HacktuiStore.Cases do
  @moduledoc """
  Ecto persistence flows for case records and case timeline entries.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias HacktuiCore.Aggregates.InvestigationCase
  alias HacktuiCore.Events.{CaseOpened, CaseTransitioned}
  alias HacktuiStore.Schema.{CaseRecord, CaseTimelineEntry, MarkingField}

  @typedoc "Slice 40: the marking and fingerprint of the alert that opened the case."
  @type open_opts :: [marking: HacktuiCore.Marking.t() | nil, fingerprint: String.t() | nil]

  @spec persist_open(module(), InvestigationCase.t(), CaseOpened.t(), open_opts()) ::
          HacktuiStore.transaction_result()
  def persist_open(repo, %InvestigationCase{} = case_record, %CaseOpened{} = event, opts \\ []) do
    case_record
    |> open_multi(event, opts)
    |> repo.transaction()
  end

  @spec persist_transition(module(), InvestigationCase.t(), CaseTransitioned.t()) ::
          HacktuiStore.transaction_result()
  def persist_transition(repo, %InvestigationCase{} = case_record, %CaseTransitioned{} = event) do
    case_record
    |> transition_multi(event)
    |> repo.transaction()
  end

  @spec open_multi(InvestigationCase.t(), CaseOpened.t(), open_opts()) :: Ecto.Multi.t()
  def open_multi(%InvestigationCase{} = case_record, %CaseOpened{} = event, opts \\ []) do
    Multi.new()
    |> Multi.insert(:case_insert, case_changeset(case_record, opts))
    |> Multi.insert(
      :case_timeline_insert,
      timeline_changeset(
        event.case_id,
        "case_opened",
        event.opened_at,
        event.actor.id,
        event.title,
        %{event_id: event.event_id}
      )
    )
  end

  @spec transition_multi(InvestigationCase.t(), CaseTransitioned.t()) :: Ecto.Multi.t()
  def transition_multi(%InvestigationCase{} = case_record, %CaseTransitioned{} = event) do
    # Guarded on the status the transition was computed against, matching the alert and
    # action paths. Without it a stale transition overwrites a fresher one.
    from_status = Atom.to_string(event.from_status)

    query =
      from(record in CaseRecord,
        where: record.case_id == ^case_record.case_id and record.status == ^from_status
      )

    Multi.new()
    |> Multi.update_all(
      :case_status_update,
      query,
      set: [status: Atom.to_string(case_record.status), updated_at: event.occurred_at]
    )
    |> Multi.run(:case_status_guard, fn _repo, %{case_status_update: {count, _}} ->
      if count == 1, do: {:ok, count}, else: {:error, {:stale_transition, from_status}}
    end)
    |> Multi.insert(
      :case_timeline_insert,
      timeline_changeset(
        event.case_id,
        "case_transitioned",
        event.occurred_at,
        event.actor.id,
        event.reason,
        %{
          event_id: event.event_id,
          from_status: Atom.to_string(event.from_status),
          to_status: Atom.to_string(event.to_status)
        }
      )
    )
  end

  defp case_changeset(%InvestigationCase{} = case_record, opts) do
    CaseRecord.changeset(%CaseRecord{}, %{
      id: Ecto.UUID.generate(),
      case_id: case_record.case_id,
      title: case_record.title,
      status: Atom.to_string(case_record.status),
      assigned_to: case_record.assigned_to,
      marking: MarkingField.for_write(Keyword.get(opts, :marking)),
      fingerprint: Keyword.get(opts, :fingerprint),
      metadata: %{
        source_alert_ids: case_record.source_alert_ids
      }
    })
  end

  defp timeline_changeset(case_id, entry_type, occurred_at, actor_id, summary, metadata) do
    CaseTimelineEntry.changeset(%CaseTimelineEntry{}, %{
      id: Ecto.UUID.generate(),
      case_id: case_id,
      entry_type: entry_type,
      summary: summary,
      occurred_at: occurred_at,
      actor_id: actor_id,
      metadata: metadata
    })
  end
end
