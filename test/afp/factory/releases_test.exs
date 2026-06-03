# @input  - Release targets, default checklist items, and manual transition notes
# @output - Assertions for release checklist gating and transition rules
# @pos    - Context tests for release readiness enforcement
defmodule Afp.Factory.ReleasesTest do
  use Afp.DataCase, async: true

  import Afp.FactoryFixtures

  alias Afp.Factory.Releases

  test "create_release_target creates default checklist" do
    app = app_fixture()
    release = release_fixture(app)

    assert length(release.release_check_items) == 9
  end

  test "ready_for_review is blocked until required checks are complete" do
    app = app_fixture()
    release = release_fixture(app)

    assert {:ok, release} = Releases.transition_release_target(release, "preparing", %{})

    assert {:error, :checklist_incomplete} =
             Releases.transition_release_target(release, "ready_for_review", %{})

    release = Releases.get_release_target!(release.id)

    Enum.each(release.release_check_items, fn item ->
      assert {:ok, _item} = Releases.update_check_item(item, %{"status" => "passed"})
    end)

    release = Releases.get_release_target!(release.id)

    assert {:ok, ready_release} =
             Releases.transition_release_target(release, "ready_for_review", %{})

    assert ready_release.status == "ready_for_review"
  end

  test "waived checks require a waiver reason" do
    app = app_fixture()
    release = release_fixture(app)
    item = hd(release.release_check_items)

    assert {:error, changeset} = Releases.update_check_item(item, %{"status" => "waived"})
    assert %{waiver_reason: ["is required when waiving a checklist item"]} = errors_on(changeset)

    assert {:ok, waived_item} =
             Releases.update_check_item(item, %{
               "status" => "waived",
               "waiver_reason" => "Not applicable to this build"
             })

    assert waived_item.status == "waived"
  end

  test "submitted and live transitions require manual notes" do
    app = app_fixture()
    release = release_fixture(app)
    {:ok, release} = Releases.transition_release_target(release, "preparing", %{})

    release = Releases.get_release_target!(release.id)

    Enum.each(
      release.release_check_items,
      &Releases.update_check_item(&1, %{"status" => "passed"})
    )

    release = Releases.get_release_target!(release.id)
    {:ok, release} = Releases.transition_release_target(release, "ready_for_review", %{})

    assert {:error, :submission_note_required} =
             Releases.transition_release_target(release, "submitted", %{})

    assert {:ok, release} =
             Releases.transition_release_target(release, "submitted", %{
               "decision_note" => "Submitted manually"
             })

    assert {:error, :live_note_and_date_required} =
             Releases.transition_release_target(release, "live", %{"decision_note" => "Approved"})

    assert {:ok, live_release} =
             Releases.transition_release_target(release, "live", %{
               "decision_note" => "Live in store",
               "released_at" => DateTime.utc_now()
             })

    assert live_release.status == "live"
  end
end
