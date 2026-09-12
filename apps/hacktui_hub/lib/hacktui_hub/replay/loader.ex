defmodule HacktuiHub.Replay.Loader do
  @moduledoc false

  alias HacktuiCore.Observation.Envelope

  @spec load_fixture!(Path.t()) :: [Envelope.t()]
  def load_fixture!(path) do
    path
    |> resolve_path()
    |> File.stream!([], :line)
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(&parse_line!/1)
  end

  defp resolve_path(path) do
    cond do
      Path.type(path) == :absolute ->
        path

      File.exists?(Path.expand(path, File.cwd!())) ->
        Path.expand(path, File.cwd!())

      true ->
        Path.expand(Path.join(["..", "..", "..", "..", "..", path]), __DIR__)
    end
  end

  defp parse_line!(line) do
    attrs = Jason.decode!(line)

    envelope = Envelope.new(attrs["source"], attrs["kind"], attrs["payload"] || %{})

    # Slice 40: a fixture line may carry the three envelope-v2 fields at the top level.
    # A fixture is untrusted input: the fingerprint must be printable and bounded (it
    # becomes a column value and an index key) and the digest must be exactly a sha256;
    # `marking` is normalised at ingest, which raises on a malformed one.
    %Envelope{
      envelope
      | received_at: parse_received_at(attrs["received_at"]),
        metadata: attrs["metadata"] || %{},
        fingerprint: parse_fingerprint(attrs["fingerprint"]),
        raw_message_sha256: parse_sha256(attrs["raw_message_sha256"]),
        marking: attrs["marking"],
        envelope_version: attrs["envelope_version"] || Envelope.version()
    }
  end

  # `\z`, not `$`: `$` matches before a trailing newline and would let one through.
  @fingerprint_shape ~r/\A[\x21-\x7E]{1,512}\z/
  @sha256_shape ~r/\A[0-9a-f]{64}\z/

  defp parse_fingerprint(nil), do: nil

  defp parse_fingerprint(value) when is_binary(value) do
    if Regex.match?(@fingerprint_shape, value) do
      value
    else
      raise ArgumentError, "invalid fixture fingerprint: printable ASCII, 1..512 bytes"
    end
  end

  defp parse_fingerprint(other),
    do: raise(ArgumentError, "invalid fixture fingerprint: #{inspect(other)}")

  defp parse_sha256(nil), do: nil

  defp parse_sha256(value) when is_binary(value) do
    if Regex.match?(@sha256_shape, value) do
      value
    else
      raise ArgumentError, "invalid fixture raw_message_sha256: 64 lowercase hex expected"
    end
  end

  defp parse_sha256(other),
    do: raise(ArgumentError, "invalid fixture raw_message_sha256: #{inspect(other)}")

  defp parse_received_at(nil), do: nil

  defp parse_received_at(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, reason} ->
        raise ArgumentError, "invalid received_at #{inspect(value)}: #{inspect(reason)}"
    end
  end
end
