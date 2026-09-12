import Config

config :hacktui_store, HacktuiStore.Repo, log: false

config :hacktui_hub,
  privacy_mask: true

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
