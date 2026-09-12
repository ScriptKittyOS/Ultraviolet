defmodule HacktuiStore.Schema.Alert do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias HacktuiStore.Schema.MarkingField

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "alerts" do
    field(:alert_id, :string)
    field(:title, :string)
    field(:severity, :string)
    field(:state, :string)
    field(:disposition, :string)
    field(:metadata, :map, default: %{})
    field(:marking, :map, default: %{})
    field(:fingerprint, :string)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(alert, attrs) do
    alert
    |> cast(attrs, [
      :id,
      :alert_id,
      :title,
      :severity,
      :state,
      :disposition,
      :metadata,
      :marking,
      :fingerprint
    ])
    |> validate_required([:alert_id, :title, :severity, :state, :disposition])
    |> MarkingField.validate()
    |> unique_constraint(:alert_id)
  end
end
