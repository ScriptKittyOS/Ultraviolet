defmodule HacktuiStore.Repo.Migrations.AddMarkingAndFingerprint do
  use Ecto.Migration

  # Slice 40. Three fields that used to die at the command -> event boundary now have a
  # home on every durable record:
  #
  #   * `marking` -- an inert classification marking (IC-ISM-shaped). NOT NULL, because a
  #     row without one is unmarked in a way nothing downstream can tell apart from
  #     "unclassified". Rows that predate this migration get `{}`: "no marking was
  #     recorded", which is the truth about them, rather than an invented "U".
  #   * `fingerprint` -- the collector's identity for the observation. On `audit_events`
  #     (where every accepted observation is recorded) it is unique per `source`, so a
  #     replayed or re-forwarded observation is one row, not two. Partial: only
  #     observation rows that carry a fingerprint take part.
  #   * `source` on `audit_events` -- the half of that identity the table did not have.

  def change do
    alter table(:alerts) do
      add(:marking, :map, null: false, default: %{})
      add(:fingerprint, :string)
    end

    alter table(:cases) do
      add(:marking, :map, null: false, default: %{})
      add(:fingerprint, :string)
    end

    alter table(:audit_events) do
      add(:marking, :map, null: false, default: %{})
      add(:fingerprint, :string)
      add(:source, :string)
    end

    create(
      unique_index(:audit_events, [:source, :fingerprint],
        name: :audit_events_source_fingerprint_index,
        where: "action = 'observation_accepted' AND fingerprint IS NOT NULL"
      )
    )
  end
end
