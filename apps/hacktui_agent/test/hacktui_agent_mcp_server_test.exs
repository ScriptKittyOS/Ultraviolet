defmodule HacktuiAgent.MCPServerTest do
  use ExUnit.Case, async: true

  alias BeamMCP.Server

  defmodule FakeToolCatalog do
    def all do
      [
        %BeamMCP.ToolSpec{
          name: :get_latest_alerts,
          command_class: :observe,
          mode: :read_only,
          description: "Read the latest alert queue entries."
        },
        %BeamMCP.ToolSpec{
          name: :propose_action,
          command_class: :contain,
          mode: :proposal,
          description: "Propose an approval-governed action request.",
          # A ToolSpec without an input_schema is a tool with no declared arguments, so the
          # server derives no keys and dispatch receives nothing. That is the package working
          # as designed: the schema is the argument contract, and a fake catalog that omits
          # one is describing a tool that takes none.
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "case_id" => %{"type" => "string"},
              "action_class" => %{"type" => "string"},
              "target" => %{"type" => "string"}
            },
            "required" => ["case_id", "action_class", "target"],
            "additionalProperties" => false
          }
        }
      ]
    end
  end

  test "initialize advertises MCP tool capability" do
    state = Server.new(tool_catalog: FakeToolCatalog, server_name: "hacktui-hermes")

    {next_state, response} =
      Server.handle_message(state, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})

    assert next_state.initialized?
    assert response["result"]["protocolVersion"] == "2025-11-25"
    assert response["result"]["capabilities"] == %{"tools" => %{"listChanged" => false}}
    assert response["result"]["serverInfo"]["name"] == "hacktui-hermes"
  end

  test "tools/list exposes MCP-compatible tool metadata" do
    state = Server.new(tool_catalog: FakeToolCatalog, server_name: "hacktui-hermes")

    {_next_state, response} =
      Server.handle_message(state, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

    assert %{"result" => %{"tools" => tools}} = response
    assert Enum.map(tools, & &1["name"]) == ["get_latest_alerts", "propose_action"]

    proposal_tool = Enum.find(tools, &(&1["name"] == "propose_action"))
    assert proposal_tool["annotations"]["destructiveHint"]
    assert proposal_tool["inputSchema"]["required"] == ["case_id", "action_class", "target"]
  end

  test "tools/call normalizes JSON arguments before dispatching" do
    parent = self()

    dispatch = fn name, args, opts ->
      send(parent, {:dispatch, name, args, opts})
      {:ok, %{received: args[:action_class], case_id: args[:case_id], target: args[:target]}}
    end

    state =
      Server.new(dispatch: dispatch, tool_catalog: FakeToolCatalog, server_name: "hacktui-hermes")

    {_next_state, response} =
      Server.handle_message(state, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "propose_action",
          "arguments" => %{
            "case_id" => "case-7",
            "action_class" => "contain",
            "target" => "host-42"
          }
        }
      })

    assert_receive {:dispatch, :propose_action, args, []}
    assert args[:case_id] == "case-7"
    # The protocol core normalises the KEY and passes the VALUE through. Turning "contain"
    # into :contain is domain knowledge and now lives in HacktuiAgent.MCP.Dispatch, which this
    # test replaces with a fake -- so the value arrives as the client sent it.
    assert args[:action_class] == "contain"
    assert args[:target] == "host-42"

    assert response["result"]["isError"] == false

    assert response["result"]["structuredContent"] == %{
             "received" => "contain",
             "case_id" => "case-7",
             "target" => "host-42"
           }
  end

  test "unknown tools return a JSON-RPC error" do
    state = Server.new(tool_catalog: FakeToolCatalog, server_name: "hacktui-hermes")

    {_next_state, response} =
      Server.handle_message(state, %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{"name" => "nope", "arguments" => %{}}
      })

    assert response["error"]["code"] == -32_601
    assert response["error"]["message"] == "Unknown tool: nope"
  end
end
