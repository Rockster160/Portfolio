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

  # `list_items` is `-> { ordered }` = `sort_order DESC NULLS LAST`, which is
  # right for choosing WHICH rows a card shows and wrong for reading them: a
  # card of steps is worked through top to bottom.
  describe "the order the boxes come out in" do
    before {
      %w[Cook Cool Chop Grate Assemble].each_with_index { |name, i|
        create(:list_item, list: list, name: name, sort_order: i + 1)
      }
    }

    it "reads in list order, first step first, with nothing said about what didn't fit", :aggregate_failures do
      post!

      expect(action.buttons.pluck("label")).to eq(%w[Cook Cool Chop Grate Assemble])
      expect(user.byte_messages.last.body).to eq("Still to do:")
    end

    # The cap still bites against the list's own order, so a long list shows the
    # rows just added rather than the bottom of the pile.
    it "still caps against the newest end of the list" do
      6.times { |i| create(:list_item, list: list, name: "Extra #{i + 1}", sort_order: 20 + i) }

      labels = post! && action.buttons.pluck("label")

      expect(labels.last).to eq("Extra 6")
      expect(labels).not_to include("Cook")
      expect(labels.length).to eq(described_class::MAX_ROWS)
    end
  end

  # A quiet truncation reads as the whole list: four things get ticked off and
  # the list is believed to be clear. The count is small print on the card,
  # not something to buzz a phone with.
  it "draws only the first ten, says how many did not fit, and keeps that out of the push", :aggregate_failures do
    14.times { |i| create(:list_item, list: list, name: "Item #{i + 1}") }
    expect(Buddy::CompanionDelivery).to receive(:deliver_plain).with(
      hash_including(push_title: "Still to do:"),
    ).and_call_original

    expect(post!).to eq(described_class::MAX_ROWS)

    expect(action.buttons.length).to eq(10)
    expect(action.buttons.pluck("label")).to include("Item 1", "Item 10")
    expect(action.buttons.pluck("label")).not_to include("Item 11")
    expect(user.byte_messages.last.body).to include("4 more")
  end

  context "with items on the list" do
    before do
      create(:list_item, list: list, name: "Lock the back door")
      create(:list_item, list: list, name: "Start the dishwasher")
    end

    # A level-2 tool drawn the normal way would arrive already ticked with the
    # list already emptied, so every row stays pending.
    it "posts one pushed message whose pending rows point at remove_list_item", :aggregate_failures do
      expect(WebPushNotifications).to receive(:send_to_byte).with(hash_including(title: "Still to do:"))

      expect(post!).to eq(2)

      expect(action.buttons.pluck("label")).to contain_exactly("Lock the back door", "Start the dishwasher")
      expect(action.buttons.pluck("status").uniq).to eq(["pending"])
      expect(list.reload.list_items.count).to eq(2)

      row = action.buttons.find { |b| b["label"] == "Lock the back door" }
      expect(row["tool_name"]).to eq("remove_list_item")
      expect(row["payload"]).to include("list_id" => list.id, "item" => "Lock the back door")
      # The rows are the list, so the per-row kind chip is off.
      expect(row).to have_key("kind_label")
      expect(row["kind_label"]).to be_nil

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

    it "removes the item when its row is executed and leaves the unticked rows live", :aggregate_failures do
      post!
      row = action.buttons.find { |b| b["label"] == "Start the dishwasher" }

      Buddy::ProposalExecutor.perform(action.id, [row["id"]])

      expect(list.reload.list_items.pluck(:name)).to eq(["Lock the back door"])
      action.reload
      expect(action.buttons.find { |b| b["id"] == row["id"] }["status"]).to eq("executed")
      expect(action.buttons.reject { |b| b["id"] == row["id"] }.pluck("status")).to eq(["pending"])
      expect(action).to be_pending
    end

    describe "ticking and unticking a row" do
      before { allow(MonitorChannel).to receive(:broadcast_to) }

      def row(label)
        action.reload.buttons.find { |b| b["label"] == label }
      end

      def check!(label, checked)
        described_class.check!(action, row(label)["id"], checked)
      end

      it "goes back and forth as often as they like, the list following every time", :aggregate_failures do
        post!

        check!("Start the dishwasher", true)
        expect(list.reload.list_items.pluck(:name)).to eq(["Lock the back door"])
        expect(row("Start the dishwasher")).to include("status" => "executed", "undoable" => true)

        check!("Start the dishwasher", false)
        expect(list.reload.list_items.pluck(:name)).to contain_exactly("Lock the back door", "Start the dishwasher")
        expect(row("Start the dishwasher")["status"]).to eq("pending")
        expect(row("Start the dishwasher")).not_to have_key("result")

        check!("Start the dishwasher", true)
        expect(list.reload.list_items.pluck(:name)).to eq(["Lock the back door"])
        expect(row("Start the dishwasher")["status"]).to eq("executed")
        expect(action.reload).to be_pending
      end

      it "stays live with every row ticked, and a repeat of the same state changes nothing", :aggregate_failures do
        post!
        check!("Start the dishwasher", true)
        check!("Lock the back door", true)
        check!("Lock the back door", true)

        expect(list.reload.list_items).to be_empty
        expect(action.reload).to be_pending
        expect(BuddyActivity.where(user: user).count).to eq(2)

        check!("Lock the back door", false)
        expect(list.reload.list_items.pluck(:name)).to eq(["Lock the back door"])
      end
    end

    describe "the list changing somewhere else" do
      before { allow(MonitorChannel).to receive(:broadcast_to) }

      def status_of(label)
        action.reload.buttons.find { |b| b["label"] == label }["status"]
      end

      it "ticks the row when the item comes off the list, and unticks it when it goes back", :aggregate_failures do
        post!

        list.list_items.remove("Lock the back door")
        expect(status_of("Lock the back door")).to eq("executed")
        expect(status_of("Start the dishwasher")).to eq("pending")
        expect(action.byte_message.reload.metadata["buttons"].pluck("status")).to include("executed")

        list.list_items.add("Lock the back door")
        expect(status_of("Lock the back door")).to eq("pending")
      end

      it "puts an item ticked off in the app back when its row is unticked" do
        post!
        list.list_items.remove("Lock the back door")

        described_class.check!(action, action.buttons.find { |b| b["label"] == "Lock the back door" }["id"], false)

        expect(list.reload.list_items.pluck(:name)).to include("Lock the back door")
      end

      it "leaves a card that has expired alone" do
        post!
        action.update!(expires_at: 1.minute.ago)

        list.list_items.remove("Lock the back door")

        expect(status_of("Lock the back door")).to eq("pending")
      end
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
