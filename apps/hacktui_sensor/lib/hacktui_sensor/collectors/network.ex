defmodule HacktuiSensor.Collectors.Network do
  @moduledoc """
  Packet capture collector using tshark.

  Emits structured `network.flow` observations for:
  - network map rendering
  - site/domain display
  - protocol/service extraction
  - severity-driven color coding in the TUI

  Also emits `system.error` observations when tshark/dumpcap fails, so
  collector failures show up in the live telemetry instead of failing silently.
  """

  use GenServer

  require Logger

  alias HacktuiCore.Commands.AcceptObservation
  alias HacktuiCore.Text
  alias HacktuiSensor.Forwarder

  # tshark fields are hostnames, SNI, URIs and column text -- all attacker-influenced.
  @max_field_bytes 512

  # build_summary/8 concatenates several capped fields, and CommandHandlers.Alerting
  # copies the summary verbatim into `title`, which the migration declares varchar(255).
  # Capping fields alone does not bound the concatenation -- a single 512-byte URI
  # overflows on its own -- and an oversized title raises Postgrex 22001, which
  # Runtime.safely_persist/3 converts into {:ok, unpersisted_result(...)}. That let an
  # attacker suppress their own alert by making it too long. The summary is what has to
  # be bounded, and 200 leaves headroom under the column.
  @max_summary_bytes 200

  # A line with no newline accumulates in the port buffer before any sanitiser sees it,
  # so line length -- and therefore memory -- is chosen by whoever is on the wire.
  # Bounding the buffer is what makes the per-field cap meaningful.
  @max_buffer_bytes 64 * 1024

  @restart_delay_ms 2_000
  @max_restart_delay_ms 60_000
  @max_restart_attempts 8

  @error_prefixes [
    "tshark:",
    "dumpcap:",
    "the capture session could not be initiated",
    "permission denied",
    "you do not have permission",
    "no such device exists",
    "there is no device named",
    "unknown interface",
    "socket:",
    "failed to",
    "see the user's guide",
    "display filters and capture filters don't have the same syntax"
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %{
      enabled?: Keyword.get(opts, :enabled?, true),
      interface: Keyword.get(opts, :interface, "any"),
      host_identity: hostname(),
      source_node: node() |> to_string(),
      port: nil,
      buffer: "",
      tshark_path: tshark_path(),
      last_error: nil,
      consecutive_failures: 0,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    cond do
      not state.enabled? ->
        {:ok, state}

      is_nil(state.tshark_path) ->
        send(self(), {:report_error, "tshark executable not found in PATH"})
        {:ok, state}

      true ->
        send(self(), :start_capture)
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:start_capture, %{enabled?: false} = state), do: {:noreply, state}

  def handle_info(:start_capture, state) do
    case state.tshark_path || tshark_path() do
      nil ->
        send(self(), {:report_error, "tshark executable not found in PATH"})
        {:noreply, %{state | port: nil, buffer: "", tshark_path: nil}}

      path ->
        args = tshark_args(state.interface)

        try do
          port =
            Port.open(
              {:spawn_executable, path},
              [:binary, :exit_status, :stderr_to_stdout, args: args]
            )

          {:noreply,
           %{
             state
             | port: port,
               buffer: "",
               tshark_path: path,
               last_error: nil,
               # Reset on a successful capture start. Without this the counter
               # accumulated over the process lifetime, so a collector that worked fine
               # but whose tshark restarted N times over hours permanently disabled
               # itself -- and stayed alive, so no supervisor restart could recover it.
               consecutive_failures: 0
           }}
        rescue
          error ->
            msg = "failed to open tshark port: #{Exception.message(error)}"
            send(self(), {:report_error, msg})
            {:noreply, %{state | port: nil, buffer: "", last_error: msg}}
        end
    end
  end

  @impl true
  def handle_info({_port, {:data, data}}, %{buffer: buffer} = state) when is_binary(data) do
    text = buffer <> data
    lines = String.split(text, "\n", trim: false)

    {complete_lines, next_buffer} =
      case lines do
        [] -> {[], ""}
        parts -> {Enum.drop(parts, -1), List.last(parts) || ""}
      end

    new_state =
      Enum.reduce(complete_lines, state, fn line, acc ->
        process_line(line, acc)
      end)

    {:noreply, %{new_state | buffer: bound_buffer(next_buffer)}}
  end

  @impl true
  def handle_info({_port, {:exit_status, status}}, state) do
    msg =
      case state.last_error do
        nil -> "capture process exited with status #{status}"
        last -> "capture process exited with status #{status} (#{last})"
      end

    failures = Map.get(state, :consecutive_failures, 0) + 1

    state =
      %{state | port: nil, buffer: "", last_error: msg}
      |> Map.put(:consecutive_failures, failures)

    if failures > @max_restart_attempts do
      # Stop retrying. One summary observation instead of an unbounded error storm.
      send(self(), {:report_error, "#{msg}; giving up after #{failures} consecutive failures"})
      {:noreply, Map.put(state, :enabled?, false)}
    else
      send(self(), {:report_error, msg})
      Process.send_after(self(), :start_capture, restart_delay_ms(failures))
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:report_error, msg}, state) do
    emit_error_observation(msg, state)
    {:noreply, %{state | last_error: msg}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning(
      "[hacktui_sensor] unmatched message in #{inspect(__MODULE__)}: #{inspect(msg)}"
    )

    {:noreply, state}
  end

  # Exponential backoff, capped. Attempt n waits @restart_delay_ms * 2^(n-1).
  defp restart_delay_ms(failures) do
    min(@restart_delay_ms * Integer.pow(2, failures - 1), @max_restart_delay_ms)
  end

  defp tshark_path, do: System.find_executable("tshark")

  defp tshark_args(interface) do
    [
      "-i",
      interface,
      "-l",
      "-n",
      "-Q",
      "-f",
      capture_filter(),
      "-T",
      "fields",
      "-E",
      "separator=\t",
      "-E",
      "occurrence=f",
      "-E",
      "quote=n",
      "-e",
      "ip.src",
      "-e",
      "ip.dst",
      "-e",
      "ipv6.src",
      "-e",
      "ipv6.dst",
      "-e",
      "tcp.srcport",
      "-e",
      "tcp.dstport",
      "-e",
      "udp.srcport",
      "-e",
      "udp.dstport",
      "-e",
      "dns.qry.name",
      "-e",
      "tls.handshake.extensions_server_name",
      "-e",
      "http.host",
      "-e",
      "http.request.method",
      "-e",
      "http.request.uri",
      "-e",
      "frame.protocols",
      "-e",
      "_ws.col.Info"
    ]
  end

  defp capture_filter do
    "tcp or udp or icmp or icmp6 or port 53"
  end

  defp process_line("", state), do: state

  defp process_line(line, state) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        state

      likely_error_line?(trimmed) ->
        emit_error_observation(trimmed, state)
        %{state | last_error: Text.ingest_or_nil(trimmed) || "collector error"}

      true ->
        fields = String.split(trimmed, "\t")

        case fields do
          [
            ipv4_src,
            ipv4_dst,
            ipv6_src,
            ipv6_dst,
            tcp_src,
            tcp_dst,
            udp_src,
            udp_dst,
            dns_name,
            tls_sni,
            http_host,
            http_method,
            http_uri,
            proto,
            info
          ] ->
            emit_observation(
              %{
                # Checked per FIELD, never on the tab-joined line: the sanitiser
                # rewrites \t to a space, and tshark's separator is tab, so scanning the
                # whole line reported every benign flow as an injection attempt and
                # floored it to "high".
                injection_attempt?:
                  Enum.any?(
                    [dns_name, tls_sni, http_host, http_uri, info],
                    &Text.suspicious?/1
                  ),
                src: sanitize_field(ipv4_src) || sanitize_field(ipv6_src),
                dst: sanitize_field(ipv4_dst) || sanitize_field(ipv6_dst),
                src_port: parse_port(tcp_src) || parse_port(udp_src),
                dst_port: parse_port(tcp_dst) || parse_port(udp_dst),
                dns_name: sanitize_field(dns_name),
                tls_sni: sanitize_field(tls_sni),
                http_host: sanitize_field(http_host),
                http_method: sanitize_field(http_method),
                http_uri: sanitize_field(http_uri),
                proto: sanitize_field(proto),
                info: sanitize_field(info),
                # The evidence commitment is over the bytes as received, before any
                # field was sanitised.
                raw_line_sha256: Text.original_sha256(trimmed)
              },
              state
            )

            state

          _ ->
            if suspicious_unparsed_line?(trimmed) do
              # Do not inline the line. It failed field parsing, so it carries no
              # structure worth preserving, and emitting it here put raw attacker
              # bytes into raw_message at severity "high". Report its shape; the
              # bytes stay recoverable through the digest.
              emit_error_observation(unparsed_line_report(trimmed), state)
              %{state | last_error: Text.ingest_or_nil(trimmed) || "unparsed output"}
            else
              state
            end
        end
    end
  end

  defp bound_buffer(buffer) when byte_size(buffer) <= @max_buffer_bytes, do: buffer

  defp bound_buffer(buffer) do
    Logger.warning(
      "[hacktui_sensor] discarding #{byte_size(buffer)} bytes of unterminated capture " <>
        "output (limit #{@max_buffer_bytes})"
    )

    ""
  end

  defp emit_observation(event, state) do
    if ignorable_flow?(event) do
      :ok
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      proto = normalize_proto(event.proto)
      service = infer_service(proto, event)
      site = pick_site(event)
      method = normalize_blank(event.http_method)
      path = normalize_blank(event.http_uri)
      # Telemetry carrying terminal control sequences is not normal traffic, and
      # sanitising it necessarily changes the text a keyword classifier reads
      # ("\e[password" is a well-formed CSI with final byte "p", leaving "assword").
      #
      # Floored to "medium", NOT "high", and the flag is carried in metadata. High would
      # promote to an alert via Detection.promote?/1, and there is no rate limit
      # anywhere in this repo -- so one control byte per packet would mean one alert per
      # packet, with title-based dedup defeated by a single varying byte in the URI.
      # That trades an evasion that cost the attacker their own alert for one that costs
      # the analyst the whole queue. Recording it at medium keeps the observation
      # queryable without generating alerts.
      #
      # Keyword classification is inherently evadable by anyone who controls the field;
      # this is not a detection engine (see detection.ex's own moduledoc).
      severity =
        if Map.get(event, :injection_attempt?, false),
          do: floor_severity(classify_traffic(proto, event.info, service, site, event)),
          else: classify_traffic(proto, event.info, service, site, event)

      src = event.src || "0.0.0.0"
      dst = event.dst || "0.0.0.0"

      summary =
        src
        |> build_summary(dst, proto, service, method, path, site, event)
        |> Text.ingest_or_nil(max_bytes: @max_summary_bytes)
        |> Kernel.||("network flow")

      payload = %{
        "src" => src,
        "dst" => dst,
        "src_port" => event.src_port,
        "dst_port" => event.dst_port,
        "src_host" => state.host_identity,
        "dst_host" => site,
        "site" => site,
        "dns_question" => event.dns_name,
        "tls_sni" => event.tls_sni,
        "http_host" => event.http_host,
        "method" => method,
        "path" => path,
        "proto" => proto,
        "service" => service,
        "info" => normalize_blank(event.info),
        "summary" => summary,
        "severity" => severity
      }

      community_id = community_id(src, event.src_port, dst, event.dst_port, proto)
      payload = Map.put(payload, "community_id", community_id)
      fingerprint = fingerprint_for(community_id, state.host_identity)

      command = %AcceptObservation{
        # Derived from the fingerprint, not a VM counter: a counter restarts at 1 with
        # the node, and the audit_id is built from this id.
        observation_id: "net-" <> binary_part(fingerprint, 0, 16),
        fingerprint: fingerprint,
        raw_message_sha256: Map.get(event, :raw_line_sha256),
        source: "sensor.network",
        kind: "network.flow",
        summary: summary,
        raw_message: summary,
        severity: severity,
        confidence: confidence_for(severity),
        payload: payload,
        metadata: %{
          collector: :packet_capture,
          severity: severity,
          # Carried so the attempt is queryable even though it does not raise an alert.
          injection_attempt?: Map.get(event, :injection_attempt?, false),
          occurred_at: DateTime.to_iso8601(now),
          observed_at: DateTime.to_iso8601(now),
          source_node: state.source_node,
          host_identity: state.host_identity,
          category: "network",
          tags: build_tags(service, site, proto)
        },
        observed_at: now,
        received_at: now,
        actor: "hacktui_sensor",
        envelope_version: 1
      }

      _ = Forwarder.accept_observation(command)
    end

    :ok
  end

  defp emit_error_observation(msg, state) do
    # All three callers pass attacker-influenceable bytes -- tshark stderr, an
    # unparsed capture line, and a spawn failure -- and this observation is emitted
    # at severity "high", so it is auto-promoted to an alert. One choke point.
    # Bounded to the summary budget, not the field budget: this msg is concatenated
    # behind a "NETWORK ERROR: " prefix and the result becomes the alert title, which
    # is varchar(255). Capping at @max_field_bytes produced a 527-byte title.
    received_sha256 = Text.original_sha256(msg)
    msg = Text.ingest_or_nil(msg, max_bytes: @max_summary_bytes - 40) || "unavailable"
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    fingerprint = fingerprint_for("neterr:" <> received_sha256, state.host_identity)

    summary =
      case state.tshark_path do
        nil -> "network collector error"
        path -> "network collector error (tshark=#{path})"
      end

    command = %AcceptObservation{
      observation_id: "neterr-" <> binary_part(fingerprint, 0, 16),
      fingerprint: fingerprint,
      raw_message_sha256: received_sha256,
      source: "sensor.network",
      kind: "system.error",
      summary: summary,
      raw_message: msg,
      severity: "high",
      confidence: 0.95,
      payload: %{
        "src" => "0.0.0.0",
        "dst" => "0.0.0.0",
        "proto" => "SYSTEM.ERROR",
        "service" => nil,
        "site" => nil,
        "summary" =>
          Text.ingest_or_nil("NETWORK ERROR: #{msg}", max_bytes: @max_summary_bytes) ||
            "NETWORK ERROR",
        "severity" => "high"
      },
      metadata: %{
        collector: :packet_capture,
        severity: "high",
        occurred_at: DateTime.to_iso8601(now),
        observed_at: DateTime.to_iso8601(now),
        source_node: state.source_node,
        host_identity: state.host_identity,
        category: "system",
        tags: ["network", "collector", "error"]
      },
      observed_at: now,
      received_at: now,
      actor: "hacktui_sensor",
      envelope_version: 1
    }

    _ = Forwarder.accept_observation(command)
    :ok
  end

  defp build_summary(src, dst, proto, service, method, path, site, event) do
    port_text =
      cond do
        event.src_port && event.dst_port -> " #{event.src_port} → #{event.dst_port}"
        event.dst_port -> " dport=#{event.dst_port}"
        true -> ""
      end

    base =
      "[#{proto}] #{src} -> #{dst}" <>
        if(site == "", do: "", else: " (#{site})") <>
        if(service == "", do: "", else: " | #{service}") <>
        port_text

    request =
      cond do
        method && path -> " #{method} #{path}"
        method -> " #{method}"
        path -> " #{path}"
        true -> ""
      end

    extra =
      cond do
        request != "" ->
          request

        normalize_blank(event.info) ->
          " | #{normalize_blank(event.info)}"

        true ->
          ""
      end

    base <> extra
  end

  defp pick_site(event) do
    event.http_host ||
      event.tls_sni ||
      event.dns_name
  end

  defp infer_service(proto, event) do
    cond do
      present?(event.http_host) -> "HTTP"
      present?(event.tls_sni) -> "HTTPS"
      present?(event.dns_name) -> "DNS"
      event.dst_port == 443 or event.src_port == 443 -> "HTTPS"
      event.dst_port == 80 or event.src_port == 80 -> "HTTP"
      event.dst_port == 53 or event.src_port == 53 -> "DNS"
      event.dst_port == 5432 or event.src_port == 5432 -> "PGSQL"
      proto == "DNS" -> "DNS"
      proto == "TLS" -> "HTTPS"
      proto == "HTTP" -> "HTTP"
      proto == "ICMP" -> "ICMP"
      proto == "ICMPV6" -> "ICMPV6"
      proto == "TCP" or proto == "DATA" -> infer_service_from_ports(event)
      proto == "UDP" -> "UDP"
      true -> proto
    end
  end

  defp infer_service_from_ports(event) do
    cond do
      event.dst_port == 443 or event.src_port == 443 -> "HTTPS"
      event.dst_port == 80 or event.src_port == 80 -> "HTTP"
      event.dst_port == 53 or event.src_port == 53 -> "DNS"
      event.dst_port == 5432 or event.src_port == 5432 -> "PGSQL"
      true -> "TCP"
    end
  end

  defp normalize_proto(nil), do: "UNKNOWN"

  defp normalize_proto(proto) do
    value =
      proto
      |> to_string()
      |> String.trim()

    cond do
      value == "" ->
        "UNKNOWN"

      String.contains?(value, "tls") ->
        "TLS"

      String.contains?(value, "http") ->
        "HTTP"

      String.contains?(value, "dns") ->
        "DNS"

      String.contains?(value, "pgsql") ->
        "PGSQL"

      String.contains?(value, "icmpv6") ->
        "ICMPV6"

      String.contains?(value, "icmp") ->
        "ICMP"

      String.contains?(value, "tcp") ->
        "TCP"

      String.contains?(value, "udp") ->
        "UDP"

      true ->
        value
        |> String.split(":")
        |> Enum.reject(&(&1 in ["eth", "frame", "sll", "linux"]))
        |> List.last()
        |> to_string()
        |> String.upcase()
    end
  end

  defp floor_severity(severity) when severity in ["high", "critical"], do: severity
  defp floor_severity(_severity), do: "medium"

  defp classify_traffic(proto, info, service, site, event) do
    info_down = String.downcase(info || "")
    site_down = String.downcase(site || "")

    cond do
      proto == "SYSTEM.ERROR" ->
        "high"

      String.contains?(info_down, "password") or
        String.contains?(info_down, "login") or
          String.contains?(info_down, "admin") ->
        "high"

      String.contains?(site_down, "auth") or
        String.contains?(site_down, "login") or
          String.contains?(site_down, "admin") ->
        "medium"

      event.dst_port == 53 or event.src_port == 53 ->
        "low"

      service in ["HTTPS", "HTTP", "DNS", "ICMP", "ICMPV6"] ->
        "low"

      true ->
        "info"
    end
  end

  defp ignorable_flow?(event) do
    loopback?(event.src) and loopback?(event.dst)
  end

  defp loopback?(nil), do: false
  defp loopback?(ip), do: String.starts_with?(ip, "127.") or ip == "::1"

  defp confidence_for("high"), do: 0.9
  defp confidence_for("critical"), do: 0.95
  defp confidence_for("medium"), do: 0.8
  defp confidence_for("low"), do: 0.65
  defp confidence_for(_), do: 0.55

  defp build_tags(service, site, proto) do
    ["network", service, proto, if(site, do: "site", else: nil)]
    |> Enum.reject(&is_nil/1)
  end

  # Slice 40. Two identities, deliberately distinct:
  #
  #   * `community_id` -- Community-ID-style: a digest of the *ordered* 5-tuple, so both
  #     directions of one conversation share it. It is carried in the payload for
  #     correlation and is NOT the fingerprint, because a fingerprint is unique per
  #     observation under `audit_events (source, fingerprint)`: a flow id alone would
  #     make every repeat of a beacon a "duplicate" and drop it.
  #   * `fingerprint` -- that flow id plus the observing host and the capture instant, so
  #     a re-forwarded copy of this observation is the same observation and the next
  #     packet of the same flow is not.
  #
  # The previous `phash2/1` over six fields was 27 bits and time-free: identical flows
  # collided across the whole history, and a VM restart could not tell its own past from
  # a fresh event.
  defp community_id(src, src_port, dst, dst_port, proto) do
    a = {to_string(src), src_port || 0}
    b = {to_string(dst), dst_port || 0}
    {first, second} = if a <= b, do: {a, b}, else: {b, a}

    {fa, pa} = first
    {fb, pb} = second

    Text.original_sha256("1:#{proto}:#{fa}:#{pa}:#{fb}:#{pb}")
  end

  defp fingerprint_for(identity, host_identity) do
    Text.original_sha256(
      "#{identity}:#{host_identity}:#{System.system_time(:nanosecond)}:" <>
        "#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp likely_error_line?(line) do
    down = String.downcase(line)

    Enum.any?(@error_prefixes, fn prefix ->
      String.contains?(down, prefix)
    end)
  end

  defp unparsed_line_report(line) do
    digest = line |> Text.original_sha256() |> String.slice(0, 16)
    "unparsed tshark output (#{byte_size(line)} bytes, sha256=#{digest})"
  end

  defp suspicious_unparsed_line?(line) do
    String.length(line) > 0 and not String.contains?(line, "\t")
  end

  defp parse_port(nil), do: nil

  defp parse_port(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" ->
        nil

      text ->
        case Integer.parse(text) do
          {n, ""} -> n
          _ -> nil
        end
    end
  end

  defp sanitize_field(nil), do: nil

  defp sanitize_field(value) do
    case Text.ingest_or_nil(value, max_bytes: @max_field_bytes) do
      nil -> nil
      "(null)" -> nil
      cleaned -> cleaned
    end
  end

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: true

  defp hostname do
    case :inet.gethostname() do
      {:ok, value} -> to_string(value)
      _ -> "unknown-host"
    end
  end
end
