defmodule HacktuiAgent.ContractsTest do
  use ExUnit.Case, async: true

  alias BeamMCP.ToolSpec
  alias HacktuiAgent.{HermesBoundary, MCP.ToolCatalog}

  test "defines a bounded MCP tool catalog" do
    read_only_tools = ToolCatalog.read_only_tools()
    proposal_tools = ToolCatalog.proposal_tools()

    assert Enum.all?(read_only_tools ++ proposal_tools, &match?(%ToolSpec{}, &1))
    assert Enum.any?(read_only_tools, &(&1.name == :get_latest_alerts))
    assert Enum.any?(read_only_tools, &(&1.name == :get_sensor_logs))
    assert Enum.any?(read_only_tools, &(&1.name == :get_jido_responses))
    assert Enum.any?(read_only_tools, &(&1.name == :get_case_timeline))
    assert Enum.any?(proposal_tools, &(&1.name == :draft_report))
    assert Enum.any?(proposal_tools, &(&1.name == :propose_action))
  end

  test "defines the hermes boundary as proposal-oriented and bounded" do
    assert :case_summary in HermesBoundary.allowed_context_fields()
    assert :audit_summary in HermesBoundary.allowed_context_fields()
    refute :secrets in HermesBoundary.allowed_context_fields()

    assert :propose_action in HermesBoundary.proposal_only_operations()
    assert :draft_report in HermesBoundary.proposal_only_operations()
  end
end
