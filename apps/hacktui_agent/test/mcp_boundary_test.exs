defmodule HacktuiAgent.MCP.BoundaryTest do
  @moduledoc """
  The MCP boundary must enforce the contract it advertises.

  The schemas were once advertised and not enforced: they built `tools/list` and nothing
  checked a call against them. Because argument normalisation also retained unrecognised
  string keys, and `ProposalService` set its safety fields with atom keys via `Map.put_new`,
  a caller could smuggle `requires_approval`/`status` past both and win the collision when
  the result was stringified.

  The schemas now live on the catalog's `BeamMCP.ToolSpec`s and the protocol core enforces
  the same one it advertises. This test reads them from the catalog, so it asserts against
  the schema the server actually uses rather than a copy that could drift from it.
  """
  use ExUnit.Case, async: true

  alias BeamMCP.Schema
  alias HacktuiAgent.MCP.{Egress, ToolCatalog}

  # The schemas moved onto the catalog's ToolSpecs when the protocol core was extracted:
  # they are this project's domain data, and a generic MCP package does not carry them.
  # Server.input_schema_for/1 was removed with them and does not come back -- it existed only
  # to reach schemas the server no longer holds. The catalog is where they live now, and
  # reading them from there is what makes this test assert the schema the server actually
  # advertises rather than a second copy.
  defp advertised_schema(name) do
    ToolCatalog.all() |> Enum.find(&(&1.name == name)) |> Map.fetch!(:input_schema)
  end

  describe "schema validation" do
    test "rejects properties the schema does not declare" do
      assert {:error, reason} =
               Schema.validate(
                 %{
                   "case_id" => "c-1",
                   "action_class" => "contain",
                   "target" => "h1",
                   "requires_approval" => false,
                   "status" => "approved"
                 },
                 advertised_schema(:propose_action)
               )

      assert reason =~ "unknown properties"
      assert reason =~ "requires_approval"
      assert reason =~ "status"
    end

    test "accepts a well-formed proposal" do
      assert :ok =
               Schema.validate(
                 %{"case_id" => "c-1", "action_class" => "contain", "target" => "h1"},
                 advertised_schema(:propose_action)
               )
    end

    test "enforces required properties" do
      assert {:error, reason} =
               Schema.validate(%{"case_id" => "c-1"}, advertised_schema(:propose_action))

      assert reason =~ "missing required"
    end

    test "enforces the advertised numeric range" do
      schema = advertised_schema(:get_latest_alerts)

      assert :ok = Schema.validate(%{"limit" => 10}, schema)
      assert {:error, reason} = Schema.validate(%{"limit" => 500}, schema)
      assert reason =~ "<= 100"
      assert {:error, _} = Schema.validate(%{"limit" => 0}, schema)
    end

    test "enforces declared types" do
      assert {:error, reason} =
               Schema.validate(%{"limit" => "ten"}, advertised_schema(:get_latest_alerts))

      assert reason =~ "integer"
    end
  end

  describe "egress masking" do
    test "masks identity-bearing fields in nested results" do
      masked =
        Egress.mask([
          %{kind: "network.flow", payload: %{"src" => "10.0.0.4", "site" => "192.168.1.1"}}
        ])

      assert [%{payload: %{"src" => "[LOCAL_HOST]", "site" => "[LOCAL_HOST]"}}] = masked
    end

    test "leaves non-identity fields untouched" do
      assert [%{kind: "network.flow"}] = Egress.mask([%{kind: "network.flow"}])
    end

    test "handles structs and bare values" do
      assert Egress.mask("plain") == "plain"
      assert Egress.mask(nil) == nil
      assert Egress.mask(%{}) == %{}
    end
  end
end
