defmodule HacktuiStore.Schema.AuditEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias HacktuiStore.Schema.MarkingField

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "audit_events" do
    field(:audit_id, :string)
    field(:action, :string)
    field(:result, :string)
    field(:actor_id, :string)
    field(:subject, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})
    field(:marking, :map, default: %{})
    field(:fingerprint, :string)
    field(:source, :string)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(audit_event, attrs) do
    audit_event
    |> cast(attrs, [
      :id,
      :audit_id,
      :action,
      :result,
      :actor_id,
      :subject,
      :occurred_at,
      :metadata,
      :marking,
      :fingerprint,
      :source
    ])
    |> validate_required([:audit_id, :action, :result, :occurred_at])
    |> MarkingField.validate()
    |> unique_constraint(:audit_id)
    |> unique_constraint([:source, :fingerprint], name: :audit_events_source_fingerprint_index)
  end
end
