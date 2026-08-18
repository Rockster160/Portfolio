require "rails_helper"

# Completing an anchor is what makes its `:after_chore` followers due —
# "Go get mail" done today puts "Go through mail" on Today. The follower
# gets no completion row and no `updated_at` bump of its own, so nothing
# about the write tells a connected client to look at it.
#
# `/chores/sync` already handles that (ChoresController#after_chore_follower_ids),
# but it only runs on a full sync — page boot, foreground, reconnect, 4am.
# On a page left open the card didn't appear for hours. These cover the two
# channels that fire immediately: the tap response (the acting device's ONLY
# channel — ChoreBroadcaster skips the actor's own tab) and the broadcast
# `chore_ids` every other device re-fetches /state for.
RSpec.describe "after_chore followers on a completion", type: :request do
  let(:owner) { create(:user) }
  let(:partner) { create(:user) }
  let!(:household) { share_chore_household!(owner, partner) }

  let!(:anchor) {
    create(
      :chore,
      created_by_user: owner, chore_household: household, name: "Go get mail",
      sharing_mode: :household, recurrence: { "freq" => "weekly", "by_day" => ["tue"] }
    )
  }
  let!(:follower) {
    create(
      :chore,
      created_by_user: owner, chore_household: household, name: "Go through mail",
      assigned_to_user: owner,
      recurrence: {
        "freq" => "after_chore", "unit" => "day", "interval" => 0, "anchor_chore_id" => anchor.id
      }
    )
  }

  before do
    owner.reload
    partner.reload
    post login_path, params: { user: { username: owner.username, password: "password123" } }
  end

  def tap_chore(chore, params={})
    post "/chores/items/#{chore.id}/completion",
      params:  params.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  def undo_chore(chore, params={})
    delete "/chores/items/#{chore.id}/completion",
      params:  params.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  it "ships the newly-due follower in the tap response" do
    tap_chore(anchor)

    expect(response.parsed_body.dig("chore", "id")).to eq(anchor.id)
    followers = response.parsed_body["chores"]
    expect(followers.pluck("id")).to eq([follower.id])
    expect(followers.first["today_visible"]).to be(true)
    expect(followers.first["due_today"]).to be(true)
  end

  it "ships the follower again on undo so it comes back off Today" do
    tap_chore(anchor)
    undo_chore(anchor)

    followers = response.parsed_body["chores"]
    expect(followers.pluck("id")).to eq([follower.id])
    expect(followers.first["today_visible"]).to be(false)
  end

  it "names the follower in the broadcast so other devices re-fetch it" do
    payloads = []
    allow(MonitorChannel).to receive(:broadcast_to) { |_user, payload| payloads << payload }

    tap_chore(anchor)

    ids = payloads.filter_map { |p| p.dig(:data, :chore_ids) }.flatten.uniq
    expect(ids).to include(anchor.id, follower.id)
  end

  it "leaves `chores` empty for a chore nothing follows" do
    plain = create(:chore, created_by_user: owner, chore_household: household, name: "Dishes")
    tap_chore(plain)

    expect(response.parsed_body["chores"]).to eq([])
  end

  # A container tap is recorded against the leaf, so the leaf's id is what
  # reaches `response_payload` — a follower anchored on the PARENT has to
  # resolve from the leaf's `parent_chore_id` or it goes missing on exactly
  # the taps the user actually makes.
  context "when the anchor is a per-person container" do
    let!(:container) {
      create(
        :chore,
        created_by_user: owner, chore_household: household, name: "Laundry",
        show_on_today_view: :never
      )
    }
    let!(:my_half) {
      create(
        :chore,
        created_by_user: owner, chore_household: household, name: "Laundry",
        parent_chore: container, assigned_to_user: owner
      )
    }
    let!(:fold) {
      create(
        :chore,
        created_by_user: owner, chore_household: household, name: "Fold Laundry",
        assigned_to_user: owner,
        recurrence: {
          "freq"            => "after_chore",
          "unit"            => "day",
          "interval"        => 0,
          "anchor_chore_id" => container.id,
        }
      )
    }

    it "resolves the parent-anchored follower from the leaf the tap landed on" do
      tap_chore(container)

      expect(response.parsed_body.dig("chore", "id")).to eq(my_half.id)
      expect(response.parsed_body["chores"].pluck("id")).to eq([fold.id])
    end
  end

  # The follower is personal + assigned, so it's invisible to the partner.
  # `accessible_chores` is what keeps it out of their payload.
  it "never leaks a follower the viewer can't see" do
    delete logout_path
    post login_path, params: { user: { username: partner.username, password: "password123" } }
    tap_chore(anchor)

    expect(response.parsed_body["chores"]).to eq([])
  end
end
