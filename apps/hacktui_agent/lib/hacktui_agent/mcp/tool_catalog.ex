defmodule HacktuiAgent.MCP.ToolCatalog do
  @moduledoc """
  Bounded MCP tool catalog derived from the approved architecture.

  Implements `BeamMCP.ToolCatalog`. Each spec carries its own `input_schema`: the protocol core
  advertises that schema in `tools/list` and enforces the same one on `tools/call`, so the
  contract a client is shown and the contract it is held to cannot drift apart.

  These schemas previously lived as per-tool clauses inside the protocol server. They are
  domain data — this project's six tools — and they belong beside the tools rather than inside
  a generic module, which is why the extracted package does not carry them.
  """

  @behaviour BeamMCP.ToolCatalog

  alias BeamMCP.ToolSpec

  @open_object %{"type" => "object", "properties" => %{}, "additionalProperties" => true}

  @read_only_tools [
    %ToolSpec{
      name: :get_latest_alerts,
      command_class: :observe,
      mode: :read_only,
      description: "Read the latest alert queue entries.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of alert queue entries to return.",
            "minimum" => 1,
            "maximum" => 100
          }
        },
        "additionalProperties" => false
      }
    },
    %ToolSpec{
      name: :get_sensor_logs,
      command_class: :observe,
      mode: :read_only,
      description: "Read recent sensor logs.",
      input_schema: @open_object
    },
    %ToolSpec{
      name: :get_jido_responses,
      command_class: :observe,
      mode: :read_only,
      description: "Read recent Jido agent responses.",
      input_schema: @open_object
    },
    %ToolSpec{
      name: :get_case_timeline,
      command_class: :observe,
      mode: :read_only,
      description: "Read the timeline for a single case.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "case_id" => %{"type" => "string", "description" => "Case identifier to inspect."}
        },
        "required" => ["case_id"],
        "additionalProperties" => false
      }
    }
  ]

  @proposal_tools [
    %ToolSpec{
      name: :draft_report,
      command_class: :notify_export,
      mode: :proposal,
      description: "Draft a report for analyst review.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "case_id" => %{
            "type" => "string",
            "description" => "Case identifier to draft a report for."
          },
          "format" => %{"type" => "string", "description" => "Optional report format hint."}
        },
        "required" => ["case_id"],
        "additionalProperties" => false
      }
    },
    %ToolSpec{
      name: :propose_action,
      command_class: :contain,
      mode: :proposal,
      description: "Propose an approval-governed action request.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "case_id" => %{
            "type" => "string",
            "description" => "Case identifier for the action request."
          },
          "action_class" => %{
            "type" => "string",
            "description" => "Action class to propose.",
            "enum" => ["contain", "observe", "notify_export"]
          },
          "target" => %{
            "type" => "string",
            "description" => "Target host, identity, or resource."
          },
          "rationale" => %{
            "type" => "string",
            "description" => "Why the action is being proposed."
          }
        },
        "required" => ["case_id", "action_class", "target"],
        "additionalProperties" => false
      }
    }
  ]

  @spec read_only_tools() :: [ToolSpec.t()]
  def read_only_tools, do: @read_only_tools

  @spec proposal_tools() :: [ToolSpec.t()]
  def proposal_tools, do: @proposal_tools

  @impl BeamMCP.ToolCatalog
  @spec all() :: [ToolSpec.t()]
  def all, do: @read_only_tools ++ @proposal_tools
end
