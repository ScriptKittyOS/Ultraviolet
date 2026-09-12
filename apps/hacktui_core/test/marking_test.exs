defmodule HacktuiCore.MarkingTest do
  use ExUnit.Case, async: true

  alias HacktuiCore.Marking

  test "setting/1: absent, banner, malformed" do
    assert Marking.setting(:error) == :absent
    assert Marking.setting({:ok, "  "}) == :absent

    assert {:ok, %{classification: "TS", dissemination_controls: ["SI", "NOFORN"]}} =
             Marking.setting({:ok, "ts//SI/NOFORN"})

    assert {:error, reason} = Marking.setting({:ok, "SECRET"})
    assert reason =~ "U, C, S or TS"
  end

  test "setting/1 refuses a banner that the enclave bound would refuse later" do
    for banner <- [
          "S//NO\e[2JFORN",
          "U//" <> String.duplicate("A", 65),
          "U//" <> Enum.join(List.duplicate("X", 33), "/")
        ] do
      assert {:error, reason} = Marking.setting({:ok, banner})
      assert reason =~ "HACKTUI_MARKING"
    end

    assert {:ok, %{dissemination_controls: ["REL TO USA, FVEY"]}} =
             Marking.setting({:ok, "U//REL TO USA, FVEY"})
  end

  test "a token with a trailing newline is refused (\\z, not $)" do
    assert_raise ArgumentError, ~r/short printable/, fn ->
      Marking.normalize!(%{classification: "S", dissemination_controls: ["NOFORN\n"]})
    end
  end

  test "normalize!/1 bounds the control lists: token shape and count" do
    good = %{"classification" => "S", "dissemination_controls" => ["REL TO USA, FVEY", "NOFORN"]}
    assert Marking.normalize!(good).dissemination_controls == ["REL TO USA, FVEY", "NOFORN"]

    assert_raise ArgumentError, ~r/short printable/, fn ->
      Marking.normalize!(%{classification: "S", dissemination_controls: ["\e[2J"]})
    end

    assert_raise ArgumentError, ~r/short printable/, fn ->
      Marking.normalize!(%{classification: "S", owner_producer: [String.duplicate("A", 65)]})
    end

    assert_raise ArgumentError, ~r/at most 32/, fn ->
      Marking.normalize!(%{classification: "S", owner_producer: List.duplicate("USA", 33)})
    end
  end

  test "banner/1 and classification_label/1" do
    m = Marking.normalize!(%{classification: "TS", dissemination_controls: ["SI", "NOFORN"]})
    assert Marking.banner(m) == "TS//SI/NOFORN"
    assert Marking.classification_label(m) == "TS"
    assert Marking.classification_label(nil) == "--"
    assert Marking.classification_label(%{}) == "?"
  end
end
