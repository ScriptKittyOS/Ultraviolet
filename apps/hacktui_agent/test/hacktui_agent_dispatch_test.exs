defmodule HacktuiAgent.DispatchTest do
  use ExUnit.Case, async: true

  alias HacktuiAgent.MCP.Dispatch

  defmodule FakeQueryService do
    def alert_queue,
      do: [
        %{
          alert_id: "alert-1",
          marking: %{classification: "S", dissemination_controls: ["NOFORN"]},
          fingerprint: "fp-1"
        }
      ]

    def sensor_logs, do: [%{sensor_id: "sensor-1", message: "accepted connection"}]
    def jido_responses, do: [%{agent_id: "agent-1", status: "ok"}]
    def case_timeline(_repo, "case-1"), do: [%{entry_type: "case_opened"}]
  end

  defmodule FakeProposalService do
    def draft_report("case-1", _opts), do: %{case_id: "case-1", summary: "Draft report scaffold"}

    def propose_action(%{case_id: "case-1", action_class: :contain, target: "host-42"}, _opts),
      do: %{case_id: "case-1", action_class: :contain, target: "host-42", requires_approval: true}

    # Echoes whatever it is handed, so a test can assert what Dispatch passed on rather than
    # what this fake decided to return.
    def propose_action(spec, _opts), do: Map.put(spec, :requires_approval, true)
  end

  test "dispatches read-only MCP tools to the hub query service" do
    assert {:ok, [%{alert_id: "alert-1"}]} =
             Dispatch.call(:get_latest_alerts, %{}, query_service: FakeQueryService)

    # Slice 40: the marking and fingerprint pass through the single egress point untouched
    # -- carried as fields, neither masked nor enforced.
    assert {:ok, [row]} =
             Dispatch.safe_call(:get_latest_alerts, %{}, query_service: FakeQueryService)

    assert row.marking == %{classification: "S", dissemination_controls: ["NOFORN"]}
    assert row.fingerprint == "fp-1"

    assert {:ok, [%{entry_type: "case_opened"}]} =
             Dispatch.call(:get_case_timeline, %{case_id: "case-1"},
               query_service: FakeQueryService
             )
  end

  test "dispatches proposal MCP tools to the proposal service" do
    assert {:ok, %{summary: "Draft report scaffold"}} =
             Dispatch.call(:draft_report, %{case_id: "case-1"},
               proposal_service: FakeProposalService
             )

    assert {:ok, %{requires_approval: true, action_class: :contain}} =
             Dispatch.call(
               :propose_action,
               %{case_id: "case-1", action_class: :contain, target: "host-42"},
               proposal_service: FakeProposalService
             )
  end

  # The protocol core passes argument values through unchanged: a client sends the string
  # "contain" and that is what arrives. Turning it into :contain is this project's vocabulary,
  # so the coercion lives here. Covered explicitly because it used to be covered by a protocol
  # test that no longer asserts it -- moving behaviour moves the burden of proving it.
  test "coerces the wire's action_class string into the domain atom" do
    assert {:ok, %{action_class: :contain}} =
             Dispatch.call(
               :propose_action,
               %{case_id: "case-1", action_class: "contain", target: "host-42"},
               proposal_service: FakeProposalService
             )
  end

  test "leaves an action_class it does not recognise alone, for the service to reject" do
    assert {:ok, %{action_class: "teleport"}} =
             Dispatch.call(
               :propose_action,
               %{case_id: "case-1", action_class: "teleport", target: "host-42"},
               proposal_service: FakeProposalService
             )
  end
end
