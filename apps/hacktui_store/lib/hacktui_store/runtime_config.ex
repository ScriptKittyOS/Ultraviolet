defmodule HacktuiStore.RuntimeConfig do
  @moduledoc """
  Production-focused validation helpers for store runtime configuration.

  `HACKTUI_START_REPO` is read three ways in production (`start_repo_setting/1`):

    * `:absent` -- the variable is unset, empty, or not a recognised boolean. Production
      refuses to boot and names both valid choices. Absence is the ambiguity; an explicit
      value never is.
    * `false` -- a supported production posture: the store boots without a repository
      (`HacktuiStore.Health` reports `:safe_no_repo`). No credential is checked, because
      nothing will connect.
    * `true` -- the repository starts, and the configured credentials must be real: the
      demo defaults and an implicit `localhost` are refused, since booting production
      against an implicit local database is the hazard this validation exists for.
  """

  @type start_repo_setting :: :absent | boolean()

  @absent_message "HACKTUI_START_REPO must be set explicitly in production: " <>
                    "true to connect to the database configured by HACKTUI_DB_*, " <>
                    "or false to boot in safe mode (safe_no_repo) with no database"

  @truthy ["1", "true", "yes", "on"]
  @falsy ["0", "false", "no", "off"]

  @doc """
  Reads the result of `System.fetch_env("HACKTUI_START_REPO")` into a three-way setting.

  `System.fetch_env/1` is the only call under which an absent variable and an explicit
  `"false"` are different values; `get_env/2` with a default collapses them.
  """
  @spec start_repo_setting(:error | {:ok, String.t()}) :: start_repo_setting()
  def start_repo_setting(:error), do: :absent

  def start_repo_setting({:ok, value}) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> :absent
      v when v in @truthy -> true
      v when v in @falsy -> false
      _ -> :absent
    end
  end

  @default_username "hacktui"
  @default_password "postgres"
  @default_hostname "localhost"
  @qualification_database "hacktui_qualification_test"

  @spec production_repo_config_errors(start_repo_setting(), term()) :: [String.t()]
  def production_repo_config_errors(:absent, _repo_config), do: [@absent_message]

  # Safe mode: nothing connects, so no credential is consulted -- even demo defaults pass.
  def production_repo_config_errors(false, _repo_config), do: []

  def production_repo_config_errors(true, repo_config) when is_list(repo_config) do
    []
    |> require_value(repo_config, :database, "HACKTUI_DB_NAME must be set")
    |> require_value(repo_config, :username, "HACKTUI_DB_USER must be set")
    |> require_value(repo_config, :password, "HACKTUI_DB_PASS must be set")
    |> require_value(repo_config, :hostname, "HACKTUI_DB_HOST must be set")
    |> reject_default(
      repo_config,
      :database,
      @qualification_database,
      "HACKTUI_DB_NAME cannot use the qualification/demo database"
    )
    |> reject_default(
      repo_config,
      :username,
      @default_username,
      "HACKTUI_DB_USER cannot use the default demo username"
    )
    |> reject_default(
      repo_config,
      :password,
      @default_password,
      "HACKTUI_DB_PASS cannot use the default demo password"
    )
    |> reject_default(
      repo_config,
      :hostname,
      @default_hostname,
      "HACKTUI_DB_HOST cannot default to localhost in production"
    )
    |> Enum.reverse()
  end

  def production_repo_config_errors(true, _repo_config) do
    ["repo configuration must be a keyword list"]
  end

  defp require_value(errors, repo_config, key, message) do
    case Keyword.get(repo_config, key) do
      nil -> [message | errors]
      "" -> [message | errors]
      _value -> errors
    end
  end

  defp reject_default(errors, repo_config, key, forbidden_value, message) do
    if Keyword.get(repo_config, key) == forbidden_value do
      [message | errors]
    else
      errors
    end
  end
end
