import Config

parse_csv = fn value ->
  value
  |> to_string()
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
end

truthy? = fn value ->
  String.downcase(to_string(value || "")) in ["1", "true", "yes", "on"]
end

if config_env() != :test do
  # Three-way (slice 38): `:absent | false | true`. `fetch_env/1`, not `get_env/2`, because a
  # default would make an unset variable indistinguishable from an explicit "false" -- and in
  # production absence is refused while explicit false is a supported safe-mode posture.
  # `HacktuiStore.RuntimeConfig` is loadable in every release that carries hacktui_store
  # (both, today: sensor -> hub -> store); outside production the parser is still used so the
  # reading is one definition, and absence simply means false as before.
  start_repo_setting =
    if Code.ensure_loaded?(HacktuiStore.RuntimeConfig) do
      HacktuiStore.RuntimeConfig.start_repo_setting(System.fetch_env("HACKTUI_START_REPO"))
    else
      if truthy?.(System.get_env("HACKTUI_START_REPO", "false")), do: true, else: :absent
    end

  start_repo = start_repo_setting == true

  enabled_backends =
    System.get_env("HACKTUI_AGENT_BACKENDS", "")
    |> parse_csv.()
    |> Enum.map(&String.to_atom/1)

  enabled_providers =
    System.get_env("HACKTUI_COLLAB_PROVIDERS", "")
    |> parse_csv.()
    |> Enum.map(&String.to_atom/1)

  hub_node =
    case System.get_env("HACKTUI_HUB_NODE") do
      nil ->
        nil

      value ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
    end

  repo_config = [
    username: System.get_env("HACKTUI_DB_USER", "hacktui"),
    password: System.get_env("HACKTUI_DB_PASS", "postgres"),
    hostname: System.get_env("HACKTUI_DB_HOST", "localhost"),
    port: String.to_integer(System.get_env("HACKTUI_DB_PORT", "5432")),
    database: System.get_env("HACKTUI_DB_NAME", "hacktui_qualification_test")
  ]

  # Guarded on the module being loadable: this file is evaluated by the release config
  # provider against the release's own code paths. Measured (slice 37): both releases carry
  # hacktui_store today (sensor -> hub -> store), so both validate here.
  if config_env() == :prod and Code.ensure_loaded?(HacktuiStore.RuntimeConfig) do
    errors =
      HacktuiStore.RuntimeConfig.production_repo_config_errors(start_repo_setting, repo_config)

    if errors != [] do
      formatted_errors = Enum.map_join(errors, "\n", &"  - #{&1}")

      raise """
      invalid production runtime configuration for :hacktui_store
      #{formatted_errors}
      """
    end
  end

  config :hacktui_store, start_repo: start_repo
  config :hacktui_store, HacktuiStore.Repo, repo_config

  config :hacktui_agent, enabled_backends: enabled_backends
  config :hacktui_collab, enabled_providers: enabled_providers
  config :hacktui_sensor, hub_node: hub_node
end
