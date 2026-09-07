defmodule HacktuiAgent.MCP.Dispatch do
  alias HacktuiAgent.MCP.Egress

  require Logger

  @moduledoc """
  Minimal MCP dispatch layer wired onto hub query and proposal services.
  """

  alias HacktuiHub.{ProposalService, QueryService}
  alias HacktuiStore.Repo

  @spec call(atom(), map(), keyword()) ::
          {:ok, term()}
          | {:error, :unknown_tool | :missing_case_id | :sensor_log_query_unavailable}
  @doc """
  Dispatches an MCP tool call, converting any raised error into an error tuple.

  Without this, a single unhandled exception in a tool propagated through
  `MCP.Server.handle_message/2` and `MCP.Stdio.loop/1` -- neither of which rescues --
  and killed the client's transport.
  """
  @spec safe_call(atom(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def safe_call(tool, args, opts) do
    # Single egress point: every successful tool result is masked here, so a new tool
    # cannot be added without masking. This was previously four hand-placed pipes at the
    # call sites, and draft_report -- which embeds the same case timeline that
    # get_case_timeline masks -- was not one of them.
    case call(tool, args, opts) do
      {:ok, result} -> {:ok, Egress.mask(result)}
      other -> other
    end
  rescue
    error ->
      Logger.error("[hacktui_mcp] tool #{inspect(tool)} raised: #{Exception.message(error)}")
      {:error, %{tool: tool, reason: Exception.message(error)}}
  catch
    # :throw was previously uncaught, so a thrown term still ended the client session --
    # while the slice-04 PLAN and commit both said this "guarantees no tool can take
    # down the transport".
    :throw, value ->
      Logger.error("[hacktui_mcp] tool #{inspect(tool)} threw: #{inspect(value)}")
      {:error, %{tool: tool, reason: "tool threw"}}

    :exit, reason ->
      Logger.error("[hacktui_mcp] tool #{inspect(tool)} exited: #{inspect(reason)}")
      {:error, %{tool: tool, reason: inspect(reason)}}
  end

  @default_limit 25

  def call(:get_latest_alerts, args, opts) do
    query_service = Keyword.get(opts, :query_service, QueryService)
    limit = Map.get(args, :limit, @default_limit)

    {:ok, Enum.take(query_service.alert_queue(), limit)}
  end

  def call(:get_sensor_logs, _args, opts) do
    query_service = Keyword.get(opts, :query_service, QueryService)
    repo = Keyword.get(opts, :repo, Repo)
    {:ok, query_service.sensor_logs(repo)}
  end

  def call(:get_jido_responses, _args, opts) do
    query_service = Keyword.get(opts, :query_service, QueryService)
    repo = Keyword.get(opts, :repo, Repo)
    {:ok, query_service.jido_responses(repo)}
  end

  def call(:get_case_timeline, %{"case_id" => case_id}, opts),
    do: call(:get_case_timeline, %{case_id: case_id}, opts)

  def call(:get_case_timeline, %{case_id: case_id}, opts) when is_binary(case_id) do
    query_service = Keyword.get(opts, :query_service, QueryService)
    repo = Keyword.get(opts, :repo, Repo)
    {:ok, query_service.case_timeline(repo, case_id)}
  end

  def call(:get_case_timeline, _args, _opts), do: {:error, :missing_case_id}

  def call(:draft_report, %{"case_id" => case_id}, opts),
    do: call(:draft_report, %{case_id: case_id}, opts)

  def call(:draft_report, %{case_id: case_id}, opts) when is_binary(case_id) do
    proposal_service = Keyword.get(opts, :proposal_service, ProposalService)
    {:ok, proposal_service.draft_report(case_id, opts)}
  end

  def call(:draft_report, _args, _opts), do: {:error, :missing_case_id}

  def call(:propose_action, action_spec, opts) when is_map(action_spec) do
    proposal_service = Keyword.get(opts, :proposal_service, ProposalService)
    {:ok, proposal_service.propose_action(coerce_action_class(action_spec), opts)}
  end

  def call(_tool, _args, _opts), do: {:error, :unknown_tool}

  # The protocol core hands values through unchanged: turning "contain" into :contain is domain
  # knowledge, and a generic MCP layer that guessed at it would be carrying this project's
  # vocabulary. The schema's enum is what constrains the value; this maps the three it allows
  # and leaves anything else alone for the service to reject.
  defp coerce_action_class(%{action_class: value} = spec) when is_binary(value) do
    %{spec | action_class: action_class_atom(value)}
  end

  defp coerce_action_class(spec), do: spec

  defp action_class_atom("contain"), do: :contain
  defp action_class_atom("observe"), do: :observe
  defp action_class_atom("notify_export"), do: :notify_export
  defp action_class_atom(other), do: other
end
