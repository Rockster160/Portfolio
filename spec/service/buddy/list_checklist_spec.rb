require "rails_helper"

# A list posted as tickable boxes, one per item.
#
# The whole point is that it rides `buddy_proposals` — the checklist Byte
# already renders, POSTs, and executes — rather than being a second shape that
# has to be taught to every one of those places. So most of what's pinned here
# is "does it look enough like a real proposal checklist for the machinery to
# pick it up", plus the one thing it deliberately does differently: the rows
# stay PENDING, because `remove_list_item` is a level-2 tool and the normal
# builder would have emptied the list while drawing the card.
RSpec.describe Buddy::ListChecklist do
  let(:user) { create(:user) }
  let!(:list) { create(:list, name: "Before Bed", user: user) }

  def post!(text: "Still to do:")
    described_class.post!(user: user, list: list.reload, text: text)
  end

  def action
    ByteAction.where(user: user, tool_name: "buddy_proposals").last
  end

  before { allow(WebPushNotifications).to receive(:send_to_byte) }

  context "with items on the list" do
    before do
      create(:list_item, list: list, name: "Lock the back door")
      create(:list_item, list: list, name: "Start the dishwasher")
    end

    it "returns how many boxes went up" do
      expect(post!).to eq(2)
    end

    it "gives every item its own row" do
      post!

      expect(action.buttons.pluck("label")).to match_array(["Lock the back door", "Start the dishwasher"])
    end

    # Empty boxes. A level-2 tool drawn the normal way would arrive already
    # ticked with the list already emptied, which is the bug this exists around.
    it "leaves every row pending" do
      post!

      expect(action.buttons.pluck("status").uniq).to eq(["pending"])
      expect(list.reload.list_items.count).to eq(2)
    end

    it "points each row at remove_list_item with what that tool executes on" do
      post!

      row = action.buttons.find { |b| b["label"] == "Lock the back door" }
      expect(row["tool_name"]).to eq("remove_list_item")
      expect(row["payload"]).to include("list_id" => list.id, "item" => "Lock the back door")
    end

    it "posts one message carrying the checklist, and pushes it" do
      expect(WebPushNotifications).to receive(:send_to_byte).with(hash_including(title: "Still to do:"))

      post!

      message = action.byte_message
      expect(message.body).to eq("Still to do:")
      expect(message.metadata).to include(
        "kind"              => "buddy_reply",
        "tool_name"         => "buddy_proposals",
        "multi_select"      => true,
        "action_request_id" => action.request_id,
      )
      expect(message.metadata["buttons"].length).to eq(2)
    end

    # The rows are the list, so a chip repeating the tool name down the card
    # would say "Remove List Item" where the item names go.
    it "turns the per-row kind chip off and words the hint as checking off" do
      post!

      row = action.buttons.first
      expect(row).to have_key("kind_label")
      expect(row["kind_label"]).to be_nil
      expect(row["hint"]).to eq("tap" => "Tap when it's done", "done" => "Done - untick to put it back")
    end

    # Ticking a row is what the whole thing is for: it runs the proposal the row
    # carries, which takes the item off the list.
    it "removes the item from the list when its row is executed" do
      post!
      row = action.buttons.find { |b| b["label"] == "Start the dishwasher" }

      Buddy::ProposalExecutor.perform(action.id, [row["id"]])

      expect(list.reload.list_items.pluck(:name)).to eq(["Lock the back door"])
      expect(action.reload.buttons.find { |b| b["id"] == row["id"] }["status"]).to eq("executed")
    end

    it "leaves the unticked rows live" do
      post!
      row = action.buttons.first

      Buddy::ProposalExecutor.perform(action.id, [row["id"]])

      still_open = action.reload.buttons.reject { |b| b["id"] == row["id"] }
      expect(still_open.pluck("status")).to eq(["pending"])
      expect(action).to be_pending
    end

    # Tonight's card and last night's point at the same items, and unticking a
    # stale row would put back what the live one just took off.
    it "retires the rows of an earlier card for the same items" do
      post!
      stale = action

      post!(text: "Round two:")

      expect(action.id).not_to eq(stale.id)
      expect(stale.reload.buttons.pluck("status").uniq).to eq(["superseded"])
    end
  end

  context "with nothing on the list" do
    it "posts nothing at all and says so with a 0" do
      expect { expect(post!).to eq(0) }.not_to(change(ByteAction, :count))
      expect(ByteMessage.count).to eq(0)
    end
  end
end
