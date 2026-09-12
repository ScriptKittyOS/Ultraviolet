defmodule HacktuiHub.ReplayLoaderTest do
  use ExUnit.Case, async: true

  alias HacktuiCore.Observation.Envelope
  alias HacktuiHub.Replay.{Loader, Runner}

  test "load_fixture!/1 parses case-1 JSONL into ordered envelopes" do
    envelopes = Loader.load_fixture!("fixtures/replay/case-1.jsonl")

    assert [first, second] = envelopes

    assert %Envelope{
             source: "demo.case-1",
             kind: "alert_observed",
             payload: %{"alert_id" => "alert-1", "indicator" => "10.0.0.4", "severity" => "high"},
             received_at: ~U[2026-03-07 13:00:00Z],
             metadata: %{"fixture" => "case-1", "sequence" => 1}
           } = first

    assert %Envelope{
             source: "demo.case-1",
             kind: "alert_observed",
             payload: %{
               "alert_id" => "alert-2",
               "indicator" => "malicious.example",
               "severity" => "medium"
             },
             received_at: ~U[2026-03-07 13:00:10Z],
             metadata: %{"fixture" => "case-1", "sequence" => 2}
           } = second
  end

  # Slice 40: a fixture is untrusted input; the identity and digest it supplies are bounded.
  describe "envelope v2 fields from a fixture" do
    defp write_fixture(lines) do
      path =
        Path.join(System.tmp_dir!(), "s40-loader-#{System.unique_integer([:positive])}.jsonl")

      File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
      on_exit(fn -> File.rm(path) end)
      path
    end

    defp line(extra) do
      Map.merge(
        %{
          "source" => "t",
          "kind" => "k",
          "payload" => %{},
          "received_at" => "2026-03-07T13:00:00Z"
        },
        extra
      )
    end

    test "fingerprint, digest and marking are read from the line" do
      digest = String.duplicate("ab", 32)

      path =
        write_fixture([
          line(%{
            "fingerprint" => "line-1",
            "raw_message_sha256" => digest,
            "marking" => %{"classification" => "C"}
          })
        ])

      assert [
               %Envelope{
                 fingerprint: "line-1",
                 raw_message_sha256: ^digest,
                 marking: %{"classification" => "C"},
                 envelope_version: 2
               }
             ] =
               Loader.load_fixture!(path)
    end

    test "a digest that is not a sha256 is refused, including one with a trailing newline" do
      for bad <- ["not-a-digest", String.duplicate("a", 64) <> "\n"] do
        path = write_fixture([line(%{"raw_message_sha256" => bad})])
        assert_raise ArgumentError, ~r/raw_message_sha256/, fn -> Loader.load_fixture!(path) end
      end
    end

    test "a fingerprint with control bytes or over 512 bytes is refused" do
      for bad <- ["fp\e[2J", String.duplicate("x", 513), "abc\n", 42] do
        path = write_fixture([line(%{"fingerprint" => bad})])
        assert_raise ArgumentError, ~r/fingerprint/, fn -> Loader.load_fixture!(path) end
      end
    end
  end

  test "run_fixture!/1 replays fixtures into ordered accepted observations" do
    accepted = Runner.run_fixture!("fixtures/replay/case-1.jsonl")

    assert [first, second] = accepted
    assert Enum.map(accepted, & &1.payload["alert_id"]) == ["alert-1", "alert-2"]
    assert Enum.map(accepted, & &1.metadata["sequence"]) == [1, 2]

    assert Enum.map(accepted, & &1.event_id) == [
             "replay-demo.case-1-alert_observed-1",
             "replay-demo.case-1-alert_observed-2"
           ]

    assert %HacktuiCore.Events.ObservationAccepted{
             source: "demo.case-1",
             kind: "alert_observed",
             payload: %{"alert_id" => "alert-1", "indicator" => "10.0.0.4", "severity" => "high"},
             accepted_at: ~U[2026-03-07 13:00:00Z],
             metadata: %{"fixture" => "case-1", "sequence" => 1}
           } = first

    assert %HacktuiCore.Events.ObservationAccepted{
             source: "demo.case-1",
             kind: "alert_observed",
             payload: %{
               "alert_id" => "alert-2",
               "indicator" => "malicious.example",
               "severity" => "medium"
             },
             accepted_at: ~U[2026-03-07 13:00:10Z],
             metadata: %{"fixture" => "case-1", "sequence" => 2}
           } = second
  end
end
