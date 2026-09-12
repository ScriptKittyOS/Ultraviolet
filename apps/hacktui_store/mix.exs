defmodule HacktuiStore.MixProject do
  use Mix.Project

  def project do
    [
      app: :hacktui_store,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # test/support/db_env.exs is loaded by every app's test_helper via Code.require_file; it is
      # not a test file, so exclude it from ExUnit's load-filter warning (slice 39).
      test_ignore_filters: [~r"^test/support/"]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {HacktuiStore.Application, []}
    ]
  end

  defp deps do
    [
      {:hacktui_core, in_umbrella: true},
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.22.4"},
      {:jason, "~> 1.4"}
    ]
  end
end
