defmodule HacktuiCore.Marking do
  @moduledoc """
  A classification marking carried on every observation, alert, case and audit row.

  The shape follows IC-ISM: a classification, the owner/producer list, and dissemination
  controls. **It is inert.** Nothing in this system reads it to enforce flow: the runtime
  runs at system-high within one enclave and hands records to a cross-domain solution,
  which is where enforcement lives. The field exists so that a future CDS has something
  to read; it is not a claim of multi-level operation.

  `HACKTUI_MARKING` is read three ways in production (`setting/1`), the same way
  `HACKTUI_START_REPO` is (slice 38):

    * `:absent` -- unset or empty. Production refuses to boot and names the variable and
      its choices. Absence is the ambiguity; an explicit value never is.
    * `{:ok, marking}` -- an explicit banner such as `U`, `S//NOFORN` or `TS//SI/NOFORN`
      becomes the enclave marking that every unmarked observation inherits.
    * `{:error, reason}` -- a banner whose classification is not one of `U`, `C`, `S`, `TS`.

  Outside production an absent variable means `enclave_default/0`.
  """

  @classifications ~w(U C S TS)

  # IC-ISM control tokens are short upper-case words with a few separators ("NOFORN",
  # "REL TO USA, FVEY"). A marking may arrive from a replay fixture, which is untrusted, so
  # each token is bounded to that shape and a list to a handful of entries.
  # `\z`, not `$`: `$` matches before a trailing newline and would let one through.
  @token_shape ~r/\A[A-Za-z0-9][A-Za-z0-9 ,.\/_-]{0,63}\z/
  @max_tokens 32

  @type t :: %{
          classification: String.t(),
          owner_producer: [String.t()],
          dissemination_controls: [String.t()],
          source: :enclave_default | :explicit
        }

  @type setting :: :absent | {:ok, t()} | {:error, String.t()}

  @absent_message "HACKTUI_MARKING must be set explicitly in production: " <>
                    "a banner whose classification is U, C, S or TS, " <>
                    "optionally followed by //DISSEM[/DISSEM] (for example U, S//NOFORN)"

  @doc "The choices a refusal names."
  @spec classifications() :: [String.t()]
  def classifications, do: @classifications

  @doc "The marking used where no variable was given outside production: unclassified."
  @spec enclave_default() :: t()
  def enclave_default do
    %{
      classification: "U",
      owner_producer: [],
      dissemination_controls: [],
      source: :enclave_default
    }
  end

  @doc """
  Reads the result of `System.fetch_env("HACKTUI_MARKING")` into a three-way setting.

  `fetch_env/1`, not `get_env/2`: a default would make an unset variable indistinguishable
  from an explicit value, and production refuses the former.
  """
  @spec setting(:error | {:ok, String.t()}) :: setting()
  def setting(:error), do: :absent

  def setting({:ok, value}) when is_binary(value) do
    case String.trim(value) do
      "" -> :absent
      banner -> parse_banner(banner)
    end
  end

  @doc "Errors that refuse a production boot, in the wording the operator sees."
  @spec production_errors(setting()) :: [String.t()]
  def production_errors(:absent), do: [@absent_message]
  def production_errors({:ok, _marking}), do: []
  def production_errors({:error, reason}), do: [reason]

  @doc """
  The enclave marking configured for this node. Raises when none is configured: in
  production `config/runtime.exs` has already refused, and elsewhere `config/*.exs` sets
  the default, so an absent key is a wiring defect, not a case to paper over with "U".
  """
  @spec enclave() :: t()
  def enclave do
    :hacktui_core |> Application.fetch_env!(:enclave_marking) |> normalize!()
  end

  @doc """
  Normalises a marking that arrived as a struct field, a fixture map (string keys, string
  source) or a stored row. `nil` stays `nil` so the caller can inherit. Anything else that
  is not a marking raises: a malformed marking must never be stored as if it were one.
  """
  @spec normalize!(term()) :: t() | nil
  def normalize!(nil), do: nil

  def normalize!(marking) when is_map(marking) do
    classification = get(marking, :classification)

    unless is_binary(classification) and classification in @classifications do
      raise ArgumentError,
            "marking classification must be one of #{Enum.join(@classifications, ", ")}, " <>
              "got: #{inspect(classification)}"
    end

    %{
      classification: classification,
      owner_producer: string_list!(get(marking, :owner_producer)),
      dissemination_controls: string_list!(get(marking, :dissemination_controls)),
      source: source!(get(marking, :source))
    }
  end

  def normalize!(other) do
    raise ArgumentError, "marking must be a map, got: #{inspect(other)}"
  end

  @doc ~S|The classification level alone, for narrow displays: `"U"`, `"TS"`; `"--"` when unmarked.|
  @spec classification_label(t() | map() | nil) :: String.t()
  def classification_label(nil), do: "--"

  def classification_label(marking) when is_map(marking) do
    case get(marking, :classification) do
      level when is_binary(level) and level in @classifications -> level
      _ -> "?"
    end
  end

  @doc ~S|The banner form for display: `"U"`, `"S//NOFORN"`, `"TS//SI/NOFORN"`.|
  @spec banner(t() | map() | nil) :: String.t()
  def banner(nil), do: "--"

  def banner(marking) when is_map(marking) do
    classification = get(marking, :classification) || "?"

    case get(marking, :dissemination_controls) do
      controls when is_list(controls) and controls != [] ->
        classification <> "//" <> Enum.join(controls, "/")

      _ ->
        classification
    end
  end

  defp parse_banner(banner) do
    [classification | controls] = String.split(banner, "//", parts: 2)
    classification = classification |> String.trim() |> String.upcase()

    controls =
      case controls do
        [] -> []
        [rest] -> rest |> String.split("/", trim: true) |> Enum.map(&String.trim/1)
      end

    if classification in @classifications do
      # Through the same bounds every other marking meets, so a banner the config
      # provider accepts is one `enclave/0` will accept too: a refusal belongs at boot,
      # not at the first ingest.
      try do
        {:ok,
         normalize!(%{
           classification: classification,
           owner_producer: [],
           dissemination_controls: Enum.reject(controls, &(&1 == "")),
           source: :explicit
         })}
      rescue
        e in ArgumentError ->
          {:error,
           "HACKTUI_MARKING is not a valid banner (got #{inspect(banner)}): " <>
             Exception.message(e)}
      end
    else
      {:error,
       "HACKTUI_MARKING classification #{inspect(classification)} is not recognised: " <>
         "it must be U, C, S or TS (got #{inspect(banner)})"}
    end
  end

  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp string_list!(nil), do: []

  defp string_list!(list) when is_list(list) do
    cond do
      length(list) > @max_tokens ->
        raise ArgumentError, "marking lists hold at most #{@max_tokens} tokens"

      Enum.all?(list, &(is_binary(&1) and Regex.match?(@token_shape, &1))) ->
        list

      true ->
        raise ArgumentError,
              "marking tokens must be short printable words, got: #{inspect(list, limit: 8)}"
    end
  end

  defp string_list!(other) do
    raise ArgumentError, "marking lists must be lists, got: #{inspect(other)}"
  end

  # A marking supplied without a source was supplied on purpose.
  defp source!(nil), do: :explicit
  defp source!(:explicit), do: :explicit
  defp source!("explicit"), do: :explicit
  defp source!(:enclave_default), do: :enclave_default
  defp source!("enclave_default"), do: :enclave_default

  defp source!(other) do
    raise ArgumentError,
          "marking source must be :explicit or :enclave_default, got: #{inspect(other)}"
  end
end
