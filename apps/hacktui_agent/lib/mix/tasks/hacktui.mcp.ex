defmodule Mix.Tasks.Hacktui.Mcp do
  use Mix.Task

  @shortdoc "Start the HackTUI MCP server over stdio"

  @impl Mix.Task
  def run(_args) do
    :logger.remove_handler(:default)
    Mix.Task.run("app.start")

    BeamMCP.Transport.Stdio.run(
      tool_catalog: HacktuiAgent.MCP.ToolCatalog,
      dispatch: &HacktuiAgent.MCP.Dispatch.safe_call/3,
      server_name: "hacktui-hermes"
    )
  end
end
