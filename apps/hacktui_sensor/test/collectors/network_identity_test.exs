defmodule HacktuiSensor.Collectors.NetworkIdentityTest do
  @moduledoc """
  Slice 40: a flow's `community_id` is the same in both directions and is NOT the
  fingerprint; every observation of the flow has its own fingerprint, so a repeated flow
  (a beacon) is never dropped as a duplicate.
  """
  use ExUnit.Case, async: false

  alias HacktuiHub.IngestService
  alias HacktuiSensor.Collectors.Network

  setup_all do
    {:ok, _started} = Application.ensure_all_started(:hacktui_sensor)
    :ok
  end

  setup do
    IngestService.reset_recent_observations()
    :ok
  end

  defp state do
    %{
      enabled?: true,
      interface: "any",
      host_identity: "test-host",
      source_node: "nonode@nohost",
      port: nil,
      buffer: "",
      tshark_path: "/usr/bin/tshark",
      last_error: nil,
      consecutive_failures: 0,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp feed(line), do: Network.handle_info({:port_stub, {:data, line <> "\n"}}, state())

  # 15 tshark columns: ip.src ip.dst ipv6.src ipv6.dst tcp.srcport tcp.dstport udp.srcport
  # udp.dstport dns tls_sni http.host method uri frame.protocols info
  defp line(src, sport, dst, dport) do
    Enum.join(
      [
        src,
        dst,
        "",
        "",
        sport,
        dport,
        "",
        "",
        "",
        "example.com",
        "example.com",
        "GET",
        "/",
        "TCP",
        "GET / HTTP/1.1"
      ],
      "\t"
    )
  end

  defp flows do
    IngestService.recent_observations()
    |> Enum.filter(&(&1.source == "sensor.network" and &1.kind == "network.flow"))
  end

  test "both directions of one conversation share a community_id" do
    {:noreply, _} = feed(line("10.0.0.4", "51000", "93.184.216.34", "443"))
    {:noreply, _} = feed(line("93.184.216.34", "443", "10.0.0.4", "51000"))

    assert [a, b] = flows()
    assert a.payload["community_id"] == b.payload["community_id"]
    assert String.length(a.payload["community_id"]) == 64
  end

  test "a repeated flow is two observations with two fingerprints" do
    {:noreply, _} = feed(line("10.0.0.4", "51000", "93.184.216.34", "443"))
    {:noreply, _} = feed(line("10.0.0.4", "51000", "93.184.216.34", "443"))

    assert [a, b] = flows()
    assert a.payload["community_id"] == b.payload["community_id"]
    refute a.fingerprint == b.fingerprint
    assert String.length(a.fingerprint) == 64
  end

  test "the digest is over the raw capture line as received, before any field is sanitised" do
    raw =
      line("10.0.0.4", "51000", "93.184.216.34", "443")
      |> String.replace("GET / HTTP/1.1", "GET /\e[2J HTTP/1.1")

    {:noreply, _} = feed(raw)

    assert [flow] = flows()
    assert flow.raw_message_sha256 == HacktuiCore.Text.original_sha256(raw)

    refute flow.raw_message_sha256 ==
             HacktuiCore.Text.original_sha256(flow.payload["raw_message"] || "")
  end

  test "a different peer is a different community_id" do
    {:noreply, _} = feed(line("10.0.0.4", "51000", "93.184.216.34", "443"))
    {:noreply, _} = feed(line("10.0.0.4", "51000", "198.51.100.7", "443"))

    assert [a, b] = flows()
    refute a.payload["community_id"] == b.payload["community_id"]
  end
end
