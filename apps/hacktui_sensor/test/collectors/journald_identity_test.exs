defmodule HacktuiSensor.Collectors.JournaldIdentityTest do
  @moduledoc """
  Slice 40: the journald port speaks `--output=json`, so an entry's `__CURSOR` is the
  observation's fingerprint and `MESSAGE` is the line that is classified and stored. The
  same seam as the hostile test: `handle_info({port, {:data, _}}, state)`.
  """
  use ExUnit.Case, async: false

  alias HacktuiHub.IngestService
  alias HacktuiSensor.Collectors.Journald

  @cursor "s=4f1c0a;i=1a2b;b=9e0f;m=3c;t=5d;x=7a"

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
      lines: 20,
      host_identity: "test-host",
      source_node: "nonode@nohost",
      port: nil,
      buffer: ""
    }
  end

  defp feed(line), do: Journald.handle_info({:port_stub, {:data, line <> "\n"}}, state())

  # The process-signals heartbeat (50ms in test) shares the buffer; read only journal rows.
  defp journal_observations do
    Enum.filter(IngestService.recent_observations(), &(&1.source == "sensor.journald"))
  end

  defp only_observation do
    assert [observation] = journal_observations()
    observation
  end

  test "a JSON entry's __CURSOR is the fingerprint and MESSAGE is the line" do
    entry =
      JSON.encode!(%{"__CURSOR" => @cursor, "MESSAGE" => "sshd[42]: Failed password for root"})

    {:noreply, _} = feed(entry)

    observation = only_observation()
    assert observation.fingerprint == "journal:" <> @cursor
    assert observation.payload["raw_message"] == "sshd[42]: Failed password for root"
    assert observation.kind == "journald.auth"
    refute observation.payload["raw_message"] =~ "__CURSOR"
  end

  test "the same entry fed twice is one observation: same fingerprint, same id" do
    entry = JSON.encode!(%{"__CURSOR" => @cursor, "MESSAGE" => "kernel: hello"})
    {:noreply, _} = feed(entry)
    first = only_observation()
    {:noreply, _} = feed(entry)

    # The observation id derives from the fingerprint (not a VM counter), so the hub's
    # buffer -- which dedupes by id -- holds one entry, and it is the same identity.
    assert [again] = journal_observations()
    assert again.fingerprint == first.fingerprint
    assert again.observation_id == first.observation_id
    assert again.observation_id =~ ~r/^journal-[0-9a-f]{16}$/
  end

  test "the digest is over the MESSAGE bytes as received, before sanitising" do
    hostile = "sudo: authentication failure \e[2J"
    entry = JSON.encode!(%{"__CURSOR" => @cursor, "MESSAGE" => hostile})
    {:noreply, _} = feed(entry)

    observation = only_observation()
    assert observation.raw_message_sha256 == HacktuiCore.Text.original_sha256(hostile)

    refute observation.raw_message_sha256 ==
             HacktuiCore.Text.original_sha256(observation.payload["raw_message"])
  end

  test "a cursor outside journald's token shape is not an identity" do
    for bad <- ["s=1;\e[2J" <> String.duplicate("x", 600), "s=abc;i=1\n"] do
      IngestService.reset_recent_observations()
      entry = JSON.encode!(%{"__CURSOR" => bad, "MESSAGE" => "kernel: hello"})
      {:noreply, _} = feed(entry)

      observation = only_observation()
      refute String.starts_with?(observation.fingerprint, "journal:")
      assert String.length(observation.fingerprint) == 64
    end
  end

  test "a list-of-strings MESSAGE (a repeated field) is joined, and its cursor kept" do
    entry =
      JSON.encode!(%{
        "__CURSOR" => @cursor,
        "MESSAGE" => ["Failed password for root", "from 10.0.0.9"]
      })

    {:noreply, _} = feed(entry)

    observation = only_observation()
    assert observation.fingerprint == "journal:" <> @cursor
    assert observation.kind == "journald.auth"
    assert observation.payload["raw_message"] =~ "10.0.0.9"
  end

  test "a journal object with a cursor and no MESSAGE emits nothing, and says so" do
    entry = JSON.encode!(%{"__CURSOR" => @cursor, "_PID" => "1"})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:noreply, _} = feed(entry)
      end)

    assert journal_observations() == []
    assert log =~ "carries no MESSAGE"
    assert log =~ @cursor
  end

  test "journalctl is asked for JSON output with --all" do
    args = Journald.journalctl_args(state())
    assert "--output=json" in args
    assert "--all" in args
    refute Enum.any?(args, &String.starts_with?(&1, "--output=short"))
  end

  test "a non-UTF-8 MESSAGE (journald's byte-list form) is still sanitised text" do
    bytes = :binary.bin_to_list("sudo: authentication failure \e[2J" <> <<0xFF, 0xFE>>)
    entry = JSON.encode!(%{"__CURSOR" => @cursor, "MESSAGE" => bytes})
    {:noreply, _} = feed(entry)

    observation = only_observation()
    assert observation.fingerprint == "journal:" <> @cursor
    assert observation.kind == "journald.auth"
    refute observation.payload["raw_message"] =~ "\e"
  end

  test "a plain (non-JSON) line is the message itself with a fallback identity that does not repeat" do
    {:noreply, _} = feed("plain text line")
    {:noreply, _} = feed("plain text line")

    assert [a, b] = journal_observations()
    assert a.payload["raw_message"] == "plain text line"
    assert String.length(a.fingerprint) == 64
    refute a.fingerprint == b.fingerprint
  end

  test "a JSON entry without a cursor falls back rather than sharing an identity" do
    entry = JSON.encode!(%{"MESSAGE" => "no cursor here"})
    {:noreply, _} = feed(entry)
    {:noreply, _} = feed(entry)

    assert [a, b] = journal_observations()
    assert a.payload["raw_message"] == "no cursor here"
    refute a.fingerprint == b.fingerprint
  end
end
