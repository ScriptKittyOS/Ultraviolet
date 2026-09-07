defmodule BeamMCP.Transport.StdioFramingTest do
  @moduledoc """
  End-to-end framing tests against the real launcher.

  There was no test of `Stdio` at all, which is why the server shipped speaking LSP
  framing (`Content-Length` headers) rather than the MCP stdio binding. The server
  advertises `2026-07-28` and `2025-11-25` and refuses anything older with `-32022`;
  the stdio binding is unchanged across every revision, and has said since `2024-11-05`:

      "Messages are delimited by newlines, and MUST NOT contain embedded newlines."

  These tests drive the actual `bin/hacktui-mcp` binary with real bytes. They are tagged
  `:mcp_e2e` because they compile the umbrella on first run.
  """
  use ExUnit.Case, async: false

  @moduletag :mcp_e2e
  @moduletag timeout: 180_000

  defp repo_root, do: Path.expand("../../..", __DIR__)

  # bin/hacktui-mcp runs `mix compile` on start, in MIX_ENV=dev. The suite runs in
  # MIX_ENV=test, so warming the test build leaves dev stale and the child recompiles --
  # printing "==> app" headers onto its stdout, which looks exactly like a framing
  # violation. Warm the *dev* build explicitly.
  setup_all do
    {_out, 0} =
      System.cmd("mix", ["compile"],
        cd: repo_root(),
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    :ok
  end

  defp mcp(input) do
    path = Path.join(System.tmp_dir!(), "mcp-in-#{System.unique_integer([:positive])}")
    File.write!(path, input)

    try do
      System.cmd("sh", ["-c", "exec ./bin/hacktui-mcp < #{path} 2>/dev/null"], cd: repo_root())
    after
      File.rm(path)
    end
  end

  defp initialize_request(id) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "framing-test", "version" => "1"}
      }
    })
  end

  test "a conformant newline-delimited request gets a response" do
    {out, 0} = mcp(initialize_request(1) <> "\n")

    assert out =~ ~s("id":1)
    assert {:ok, decoded} = out |> String.split("\n", trim: true) |> hd() |> Jason.decode()
    assert decoded["result"]["serverInfo"]["name"] == "hacktui-hermes"
  end

  test "responses are newline-delimited, not Content-Length framed" do
    {out, 0} = mcp(initialize_request(2) <> "\n")

    refute out =~ "Content-Length:",
           "MCP stdio responses must be newline-delimited JSON, not LSP-framed"

    assert String.ends_with?(out, "\n")

    # every non-empty line must be a complete JSON message on its own
    for line <- String.split(out, "\n", trim: true) do
      assert {:ok, _} = Jason.decode(line)
    end
  end

  test "legacy Content-Length input is still accepted" do
    body = initialize_request(3)
    framed = "Content-Length: #{byte_size(body)}\r\n\r\n" <> body

    {out, 0} = mcp(framed)

    assert out =~ ~s("id":3)
  end

  test "the shipped smoke client completes" do
    # bin/hacktui-mcp-smoke writes newline-delimited JSON, i.e. correct MCP framing.
    # Against the previous LSP-only reader it hung until killed. README tells users to
    # run it, so it must work.
    {out, status} =
      System.cmd(Path.join(repo_root(), "bin/hacktui-mcp-smoke"), [],
        cd: repo_root(),
        stderr_to_stdout: true
      )

    assert status == 0, "smoke client failed: #{out}"
    assert out =~ "MCP initialize ok"

    # The banner alone is not evidence. The client reads response["result"], which an
    # error response does not carry, so it printed "MCP initialize ok" and exited 0 over
    # a -32022 refusal (16j round 1, r1-B1 = r2-B1). These assert what the server
    # actually returned, so a client that reports success on a refusal fails here.
    assert out =~ "protocolVersion=2025-11-25"
    assert out =~ "server=hacktui-hermes"
    refute out =~ "=None"
  end

  # 16j round 1, r2-B3 = r1-R2. The swap enlarged this surface and nothing exercised it.
  # These pin what the launcher answers, so a later revision move cannot change the
  # refusal or the discovery shape without a test going red.
  test "a revision the server does not speak is refused with -32022, not served" do
    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "framing-test", "version" => "1"}
        }
      })

    {out, 0} = mcp(request <> "\n")
    response = out |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert %{"error" => %{"code" => -32_022, "data" => data}} = response
    assert data["requested"] == "2024-11-05"
    assert "2025-11-25" in data["supported"]
    refute Map.has_key?(response, "result")
  end

  test "server/discover answers with no initialize, and batches are refused" do
    {out, 0} = mcp(~s({"jsonrpc":"2.0","id":1,"method":"server/discover"}\n))
    response = out |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert %{"result" => result} = response
    assert result["serverInfo"]["name"] == "hacktui-hermes"
    assert result["protocolVersions"] == ["2026-07-28", "2025-11-25"]

    {batch_out, 0} = mcp(~s([{"jsonrpc":"2.0","id":1,"method":"server/discover"}]\n))
    batch = batch_out |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert %{"error" => %{"code" => code}} = batch
    assert is_integer(code)
  end

  # 16j round 1, r2-B6. structuredContent.error was a JSON string carrying Elixir
  # inspect/1 output and is now an object. Nothing asserted the shape either way, which
  # is why the change passed unnoticed. This pins the object so it cannot drift back.
  test "a rejected tools/call returns structuredContent.error as an object, not a string" do
    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"},
        "params" => %{"name" => "propose_action", "arguments" => %{}}
      })

    {out, 0} = mcp(request <> "\n")
    response = out |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    error = get_in(response, ["result", "structuredContent", "error"])

    assert is_map(error), "expected an object, got: #{inspect(error)}"
    assert error["tool"] == "propose_action"
    assert is_binary(error["reason"])
    refute error["reason"] =~ "%{", "Elixir inspect/1 output must not reach the wire"
  end

  # 16j rows 3, 4, 7 and 9. The §10 surface disclosure lives in these tests rather than in
  # prose: a test pins one behaviour and fails when it moves, where a sentence about the
  # surface can overstate what it covers. Each was proved red against base b425f63.
  #
  # ping carrying a _meta revision is refused, under 2026-07-28 and 2025-11-25 alike.
  # Deliberately has no test here: it is a defect in beam_mcp 0.1.0 (SCR-257), and a test
  # pinning it would pin the defect.

  test "row 3: initialize with no params answers 2025-11-25, not the pre-swap revision" do
    {out, 0} = mcp(~s({"jsonrpc":"2.0","id":1,"method":"initialize"}\n))
    response = out |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert response["result"]["protocolVersion"] == "2025-11-25"
  end

  test "row 4: a modern-era request is answered with resultType and a _meta serverInfo" do
    request =
      ~s({"jsonrpc":"2.0","id":1,"method":"shutdown","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}})

    {out, 0} = mcp(request <> "\n")
    response = out |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    result = response["result"]

    assert result["resultType"] == "complete"
    assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "hacktui-hermes"
  end

  test "row 7: a rejected tools/call puts a plain sentence in content, not an Elixir map" do
    request =
      ~s({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"propose_action","arguments":{}}})

    {out, 0} = mcp(request <> "\n")
    response = out |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    text = get_in(response, ["result", "content", Access.at(0), "text"])

    assert is_binary(text)
    assert text =~ "propose_action: invalid arguments"
    refute text =~ "%{", "Elixir inspect/1 output must not reach content"
    refute text =~ ":propose_action", "an Elixir atom literal must not reach content"
  end

  test "row 9: an unsupported revision arriving via _meta is refused, not served" do
    request =
      ~s({"jsonrpc":"2.0","id":1,"method":"tools/list","_meta":{"io.modelcontextprotocol/protocolVersion":"2024-11-05"}})

    {out, 0} = mcp(request <> "\n")
    response = out |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert %{"error" => %{"code" => -32_022, "data" => data}} = response
    assert data["requested"] == "2024-11-05"
    refute Map.has_key?(response, "result"), "the tool list must not be served"
  end
end
