defmodule HacktuiStore.Schema.CaseRecord do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias HacktuiStore.Schema.MarkingField

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "cases" do
    field(:case_id, :string)
    field(:title, :string)
    field(:status, :string)
    field(:assigned_to, :string)
    field(:metadata, :map, default: %{})
    field(:marking, :map, default: %{})
    field(:fingerprint, :string)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(case_record, attrs) do
    case_record
    |> cast(attrs, [
      :id,
      :case_id,
      :title,
      :status,
      :assigned_to,
      :metadata,
      :marking,
      :fingerprint
    ])
    |> validate_required([:case_id, :title, :status])
    |> MarkingField.validate()
    |> unique_constraint(:case_id)
  end
end
