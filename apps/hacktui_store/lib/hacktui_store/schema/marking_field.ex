defmodule HacktuiStore.Schema.MarkingField do
  @moduledoc """
  The `marking` column shared by alerts, cases and audit events (slice 40).

  A row is written with a well-formed marking or not at all: the column is NOT NULL and
  the changeset refuses a marking without a recognised classification. Rows written before
  the column existed carry `{}`, which reads as "no marking was recorded" -- never as "U".
  """

  import Ecto.Changeset

  alias HacktuiCore.Marking

  @doc """
  Requires `:marking` to be present and well-formed on an insert changeset.

  Checked on the APPLIED value (`get_field/2`), not on the change: the column default is
  `%{}`, so an absent marking is never a change and `validate_change/3` would never run,
  and `validate_required/2` counts `%{}` as present. Both were measured in this slice's
  own test before this version: the guard passed an unmarked row.
  """
  @spec validate(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate(changeset) do
    case get_field(changeset, :marking) do
      nil ->
        add_error(changeset, :marking, "can't be blank")

      marking ->
        try do
          _ = Marking.normalize!(marking)
          changeset
        rescue
          e in ArgumentError -> add_error(changeset, :marking, Exception.message(e))
        end
    end
  end

  @doc "The marking to store: the one given, normalised, or the enclave's when none was."
  @spec for_write(Marking.t() | map() | nil) :: map()
  def for_write(nil), do: Marking.enclave()
  def for_write(marking), do: Marking.normalize!(marking)
end
