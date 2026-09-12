defmodule HacktuiSensor do
  @moduledoc """
  Sensor runtime boundary metadata and collector orchestration.
  """

  alias HacktuiCore.Commands.AcceptObservation
  alias HacktuiCore.Text
  alias HacktuiSensor.Forwarder

  @collectors [:journald, :process_signals, :packet_capture]
  @default_process_interval_ms 5_000
  @default_journal_lines 10

  @spec collectors() :: [atom()]
  def collectors, do: @collectors

  @spec start_collectors() :: :ok
  def start_collectors do
    collector_specs()
    |> Enum.each(fn spec ->
      case DynamicSupervisor.start_child(HacktuiSensor.CollectorsSupervisor, spec) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end)

    :ok
  end

  defp collector_specs do
    [
      {HacktuiSensor.Collectors.Journald, journald_opts()},
      {HacktuiSensor.Collectors.ProcessSignals, process_signal_opts()},
      {HacktuiSensor.Collectors.Network, network_opts()}
    ]
  end

  defp env_enabled?(var) do
    System.get_env(var) in ["1", "true", "TRUE"]
  end

  defp network_opts do
    app_config = Application.get_env(:hacktui_sensor, __MODULE__, [])

    [
      # Opt-in: packet capture is a privileged, host-wide side effect. Enable with
      # HACKTUI_SENSOR_NETWORK=1 or config :hacktui_sensor, HacktuiSensor, network_enabled: true
      enabled?: Keyword.get(app_config, :network_enabled, env_enabled?("HACKTUI_SENSOR_NETWORK")),
      interface: Keyword.get(app_config, :network_interface, "any")
    ]
  end

  defp process_signal_opts do
    [
      interval_ms:
        Application.get_env(:hacktui_sensor, __MODULE__, [])
        |> Keyword.get(:process_signals_interval_ms, @default_process_interval_ms)
    ]
  end

  defp journald_opts do
    app_config = Application.get_env(:hacktui_sensor, __MODULE__, [])

    [
      # Opt-in: streams the host journal. HACKTUI_SENSOR_JOURNALD=1 to enable.
      enabled?:
        Keyword.get(app_config, :journald_enabled, env_enabled?("HACKTUI_SENSOR_JOURNALD")),
      lines: Keyword.get(app_config, :journald_lines, @default_journal_lines)
    ]
  end

  # --- Nested Collector Modules ---

  defmodule Collectors.ProcessSignals do
    require Logger
    @moduledoc false
    use GenServer

    @default_interval_ms 5_000

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      state = %{
        interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
        host_identity: hostname(),
        source_node: node() |> to_string()
      }

      Process.send_after(self(), :collect, 0)
      {:ok, state}
    end

    @impl true
    def handle_info(:collect, state) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      payload = normalized_payload(state, now)

      # Slice 40: identity that survives a restart. The heartbeat has no OS-level identity
      # (that is a later collector's); host + node + instant is what it is. The observation
      # id derives from it rather than from a VM counter that restarts at 1.
      fingerprint =
        Text.original_sha256(
          "process_signals:#{state.host_identity}:#{state.source_node}:" <>
            "#{DateTime.to_iso8601(now)}:#{System.unique_integer([:positive, :monotonic])}"
        )

      command = %AcceptObservation{
        observation_id: "obs-" <> binary_part(fingerprint, 0, 16),
        fingerprint: fingerprint,
        source: "sensor.process_signals",
        summary: "Process signals heartbeat from #{state.host_identity}",
        raw_message: inspect(payload),
        severity: :low,
        confidence: 0.6,
        kind: "process_signals",
        payload: payload,
        metadata: %{
          collector: :process_signals,
          path: :live,
          severity: "info",
          occurred_at: DateTime.to_iso8601(now),
          observed_at: DateTime.to_iso8601(now),
          source_node: state.source_node,
          host_identity: state.host_identity
        },
        observed_at: now,
        received_at: now,
        actor: "hacktui_sensor",
        envelope_version: 1
      }

      _ = Forwarder.accept_observation(command)

      Process.send_after(self(), :collect, state.interval_ms)
      {:noreply, state}
    end

    def handle_info(msg, state) do
      Logger.warning(
        "[hacktui_sensor] unmatched message in #{inspect(__MODULE__)}: #{inspect(msg)}"
      )

      {:noreply, state}
    end

    defp normalized_payload(state, now) do
      message_queue_len = Process.info(self(), :message_queue_len) |> elem(1)
      reductions = Process.info(self(), :reductions) |> elem(1)
      pid_text = inspect(self())

      %{
        "summary" => "BEAM node health check | mq=#{message_queue_len} red=#{reductions}",
        "observed_at" => DateTime.to_iso8601(now),
        "node" => state.source_node,
        "host" => state.host_identity,
        "pid" => pid_text,
        "message_queue_len" => message_queue_len,
        "reductions" => reductions
      }
    end

    defp hostname do
      case :inet.gethostname() do
        {:ok, value} -> to_string(value)
        _ -> "unknown-host"
      end
    end
  end

  defmodule Collectors.Journald do
    require Logger
    @moduledoc false
    use GenServer

    # Resolved at runtime. As a module attribute this baked the build host's
    # filesystem into the release: a container without systemd got nil forever.
    defp journalctl_path, do: System.find_executable("journalctl")

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      state = %{
        enabled?: Keyword.get(opts, :enabled?, true),
        lines: Keyword.get(opts, :lines, 20),
        host_identity: hostname(),
        source_node: node() |> to_string(),
        port: nil,
        buffer: ""
      }

      send(self(), :boot)
      {:ok, state}
    end

    @impl true
    def handle_info(:boot, %{enabled?: false} = state), do: {:noreply, state}
    def handle_info(:boot, %{enabled?: true} = state), do: {:noreply, start_journal_stream(state)}

    @impl true
    def handle_info({_port, {:data, data}}, %{buffer: buffer} = state) when is_binary(data) do
      text = buffer <> data
      lines = String.split(text, "\n", trim: false)

      {complete_lines, next_buffer} =
        case lines do
          [] -> {[], ""}
          parts -> {Enum.drop(parts, -1), List.last(parts) || ""}
        end

      Enum.each(complete_lines, fn line ->
        line
        |> String.trim()
        |> maybe_emit_observation(state)
      end)

      {:noreply, %{state | buffer: bound_buffer(next_buffer)}}
    end

    def handle_info({_port, {:exit_status, _status}}, state) do
      # Same backoff the network collector got: this previously rescheduled every 2s
      # forever, which with journalctl absent is an unbounded respawn loop.
      failures = Map.get(state, :consecutive_failures, 0) + 1
      state = %{state | port: nil, buffer: ""} |> Map.put(:consecutive_failures, failures)

      if failures > 8 do
        Logger.error("[hacktui_sensor] journald capture giving up after #{failures} failures")
        {:noreply, Map.put(state, :enabled?, false)}
      else
        Process.send_after(self(), :boot, min(2_000 * Integer.pow(2, failures - 1), 60_000))
        {:noreply, state}
      end
    end

    def handle_info(msg, state) do
      Logger.warning(
        "[hacktui_sensor] unmatched message in #{inspect(__MODULE__)}: #{inspect(msg)}"
      )

      {:noreply, state}
    end

    defp start_journal_stream(%{enabled?: true} = state) do
      cond do
        is_nil(journalctl_path()) ->
          state

        true ->
          port =
            Port.open(
              {:spawn_executable, journalctl_path()},
              [:binary, :exit_status, :stderr_to_stdout, args: journalctl_args(state)]
            )

          %{state | port: port, buffer: ""}
      end
    end

    # Slice 40: JSON output carries `__CURSOR`, the journal's own identity for the entry,
    # which becomes the observation's fingerprint; `MESSAGE` is the line. `--all` is
    # load-bearing: without it journalctl encodes any field over 4096 bytes as null, so a
    # long line would lose its text and its classification.
    # The 64 KiB line bound below still applies to whatever comes back.
    @doc false
    def journalctl_args(state) do
      [
        "--no-pager",
        "--output=json",
        "--all",
        "--follow",
        "--lines=#{state.lines}"
      ]
    end

    # Line length is chosen by whoever writes to the journal, and the buffer fills
    # before any sanitiser sees it.
    defp bound_buffer(buffer) when byte_size(buffer) <= 64 * 1024, do: buffer

    defp bound_buffer(buffer) do
      Logger.warning(
        "[hacktui_sensor] discarding #{byte_size(buffer)} bytes of unterminated journal line"
      )

      ""
    end

    defp maybe_emit_observation("", _state), do: :ok

    defp maybe_emit_observation(raw_line, state) do
      # A journald line is untrusted: any local process that can write to the journal
      # chooses these bytes, and they previously reached raw_message, summary and the
      # payload with no sanitiser at all. Classify the cleaned text so what drives the
      # decision is the same text that gets stored and rendered.
      #
      # Slice 40: the port now speaks `--output=json`, so a line is a JSON object whose
      # MESSAGE is the text and whose __CURSOR is the entry's identity. A line that is
      # not such an object (a stray stderr line, or a test feeding plain text) is
      # treated as the message itself, with a content-and-instant fallback identity.
      case unwrap_journal_line(raw_line) do
        {:no_message, cursor} ->
          # A journal object with a cursor but no MESSAGE. Never dropped silently: the
          # cursor names the entry an operator can look up.
          Logger.warning("[hacktui_sensor] journal entry #{inspect(cursor)} carries no MESSAGE")
          :ok

        {message, cursor} ->
          ingest_journal_message(message, cursor, state)
      end
    end

    defp ingest_journal_message(message, cursor, state) do
      case Text.ingest(message) do
        {:ok, line} ->
          emit_journal_observation(
            line,
            journal_fingerprint(cursor, message, state),
            Text.original_sha256(message),
            state
          )

        {:error, reason} ->
          # Never drop silently. A gap an operator can see is categorically different
          # from one they cannot, and the digest keeps the original bytes referenceable.
          Logger.warning(
            "[hacktui_sensor] dropped journal line (#{reason}, #{byte_size(message)} bytes, " <>
              "sha256=#{String.slice(Text.original_sha256(message), 0, 16)})"
          )

          :ok
      end
    end

    # journald's JSON shapes for MESSAGE (journalctl(1), "json"): a string; a list of byte
    # values when the field is not valid UTF-8; a list of strings when the field occurs
    # more than once in the entry; null or absent when there is none (with `--all`, only
    # when there truly is none). Every shape is untrusted bytes and goes through
    # Text.ingest/1 the same way. A line that is not a journal object at all (stderr
    # noise, or a test feeding plain text) is treated as the message itself.
    defp unwrap_journal_line(raw_line) do
      case JSON.decode(raw_line) do
        {:ok, %{"MESSAGE" => message} = entry} when is_binary(message) ->
          {message, journal_cursor(entry)}

        {:ok, %{"MESSAGE" => parts} = entry} when is_list(parts) ->
          {journal_message_from_list(parts, raw_line), journal_cursor(entry)}

        {:ok, %{"__CURSOR" => _} = entry} ->
          {:no_message, journal_cursor(entry)}

        _not_a_journal_object ->
          {raw_line, nil}
      end
    end

    defp journal_message_from_list(parts, raw_line) do
      cond do
        parts != [] and Enum.all?(parts, &(is_integer(&1) and &1 in 0..255)) ->
          :binary.list_to_bin(parts)

        parts != [] and Enum.all?(parts, &is_binary/1) ->
          Enum.join(parts, "\n")

        true ->
          raw_line
      end
    end

    # A cursor is journald's own token: `s=…;i=…;b=…;m=…;t=…;x=…`, hex and separators,
    # ~130 bytes. It is still bytes from a process we do not control, and it becomes a
    # column value and a fingerprint, so it is bounded to that shape; anything else is
    # treated as no cursor and the line gets the fallback identity.
    # `\z`, not `$`: `$` matches before a trailing newline.
    @cursor_shape ~r/\A[A-Za-z0-9=;_-]{1,512}\z/

    defp journal_cursor(%{"__CURSOR" => cursor}) when is_binary(cursor) do
      if Regex.match?(@cursor_shape, cursor), do: cursor, else: nil
    end

    defp journal_cursor(_entry), do: nil

    # The cursor is journald's identity for the entry: stable across a re-read of the same
    # journal, so a re-forwarded line is one observation. Without one, the content and the
    # instant are the best available and do not collide across restarts.
    defp journal_fingerprint(cursor, _message, _state) when is_binary(cursor),
      do: "journal:" <> cursor

    defp journal_fingerprint(nil, message, state) do
      Text.original_sha256(
        "journald:#{state.host_identity}:#{System.system_time(:nanosecond)}:" <>
          "#{System.unique_integer([:positive, :monotonic])}:" <> Text.original_sha256(message)
      )
    end

    defp emit_journal_observation(line, fingerprint, received_sha256, state) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {kind, raw_summary, severity} = classify_line(line)

      # Bounded for the same reason as the network collector: the summary becomes the
      # alert title, and `title` is varchar(255).
      summary = Text.ingest_or_nil(raw_summary, max_bytes: 200) || "journal event"

      command = %AcceptObservation{
        # From the fingerprint, not a VM counter; the digest is over the
        # MESSAGE bytes as received, before Text.ingest/1.
        observation_id: "journal-" <> binary_part(Text.original_sha256(fingerprint), 0, 16),
        fingerprint: fingerprint,
        raw_message_sha256: received_sha256,
        source: "sensor.journald",
        kind: kind,
        summary: summary,
        raw_message: line,
        severity: severity,
        confidence: if(severity in ["high", "critical"], do: 0.9, else: 0.65),
        payload: %{
          "summary" => summary,
          "raw_message" => line,
          "severity" => severity,
          "host" => state.host_identity,
          "node" => state.source_node,
          "observed_at" => DateTime.to_iso8601(now)
        },
        metadata: %{
          collector: :journald,
          path: :live,
          occurred_at: DateTime.to_iso8601(now),
          observed_at: DateTime.to_iso8601(now),
          source_node: state.source_node,
          host_identity: state.host_identity,
          severity: severity
        },
        observed_at: now,
        received_at: now,
        actor: "hacktui_sensor",
        envelope_version: 1
      }

      _ = Forwarder.accept_observation(command)
      :ok
    end

    defp classify_line(line) do
      lower = String.downcase(line)

      cond do
        String.contains?(lower, "apparmor=\"denied\"") or
            String.contains?(lower, "audit: type=1400") ->
          {"journald.security", "apparmor/audit denial detected", "high"}

        String.contains?(lower, "ptrace") and String.contains?(lower, "denied") ->
          {"journald.security", "ptrace denied", "high"}

        String.contains?(lower, "sudo") and String.contains?(lower, "authentication failure") ->
          {"journald.auth", "sudo authentication failure", "high"}

        String.contains?(lower, "failed password") ->
          {"journald.auth", "failed password attempt", "medium"}

        String.contains?(lower, "segfault") ->
          {"journald.process", "process crash/segfault detected", "medium"}

        true ->
          {"journald", shorten(line, 120), "info"}
      end
    end

    defp hostname do
      case :inet.gethostname() do
        {:ok, value} -> to_string(value)
        _ -> "unknown-host"
      end
    end

    defp shorten(text, max_len) do
      text = to_string(text)

      if String.length(text) <= max_len do
        text
      else
        String.slice(text, 0, max_len - 1) <> "…"
      end
    end
  end
end
