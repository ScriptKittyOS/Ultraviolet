import Config

config :hacktui_store, HacktuiStore.Repo,
  username: System.get_env("HACKTUI_DB_USER", "hacktui"),
  password: System.get_env("HACKTUI_DB_PASS", "postgres"),
  hostname: System.get_env("HACKTUI_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("HACKTUI_DB_PORT", "5432")),
  database: System.get_env("HACKTUI_DB_NAME", "hacktui_qualification_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

# Slice 40: the enclave marking outside production. Production has no default -- see
# config/runtime.exs, which refuses to boot when HACKTUI_MARKING is absent. The marking is
# inert: nothing reads it to enforce flow.
config :hacktui_core,
  enclave_marking: %{
    classification: "U",
    owner_producer: [],
    dissemination_controls: [],
    source: :enclave_default
  }

# The collector's production cadence is 5s (`hacktui_sensor.ex` @default_process_interval_ms).
# `HacktuiSensorTest` clears recent observations as its first statement, erasing the boot-time
# collection, then waits 20 x 100ms = 2s for the next one -- which cannot arrive. The 2s budget
# is the intent; 5s is a production number that does not belong in a test run.
config :hacktui_sensor, HacktuiSensor, process_signals_interval_ms: 50
