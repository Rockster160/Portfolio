require "rails_helper"

# Rocco: "Asking to be shown a list should give a checkable list of items - just
# like how we do the Before Bed items."
#
# Before this, the answer to "what's on TODO" was the names in a sentence, or a
# link. Both hand back something the person then has to go and act on somewhere
# else, when the thing they wanted to do was tick it off.
RSpec.describe "show_list tool" do
  let(:user) { create(:user) }
  let(:conversation) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let(:ctx)   { Buddy::ToolContext.new(user, conversation: conversation) }
  let(:tool)  { Buddy::Tools[:show_list] }
  let!(:list) { create(:list, name: "Groceries", user: user) }

  before { allow(WebPushNotifications).to receive(:send_to_byte) }

  def execute(name: "groceries")
    tool[:execute].call(tool[:confirm].call({ list: name }, ctx)[:resolved], ctx)
  end

  def action
    ByteAction.where(user: user, tool_name: "buddy_proposals").last
  end

  # Level 1: showing somebody their own list changes nothing and asking
  # permission to do it is a round spent on nothing.
  it "runs without being tapped" do
    expect(tool[:auto]).to be(true)
  end

  it "draws a tickable row per item" do
    create(:list_item, list: list, name: "Oat milk")
    create(:list_item, list: list, name: "Bread")

    expect(execute[:shown]).to eq(2)
    expect(action.buttons.pluck("label")).to contain_exactly("Oat milk", "Bread")
    expect(action.buttons.pluck("status").uniq).to eq(["pending"])
  end

  # The rows are `remove_list_item` proposals, so a tick checks the item off the
  # real list rather than acknowledging something in the thread.
  it "ticks off the actual list item" do
    create(:list_item, list: list, name: "Oat milk")
    execute

    expect(action.buttons.first["tool_name"]).to eq("remove_list_item")
  end

  # The list's own name is the heading. A canned lead-in would be the same
  # sentence under every list forever, and the model has already written the
  # words above it in its own voice.
  it "heads the card with the list's name and nothing else" do
    create(:list_item, list: list, name: "Oat milk")
    execute

    expect(user.byte_messages.last.body).to eq("Groceries")
  end

  it "caps a long list and says what didn't fit" do
    12.times { |i| create(:list_item, list: list, name: "Item #{i + 1}") }

    expect(execute[:shown]).to eq(Buddy::ListChecklist::MAX_ROWS)
    expect(user.byte_messages.last.body).to include("+2 more on the list")
  end

  # The card IS the answer, so there is nothing to add on top of one that went
  # up. An empty list posts no card at all, and that is the one case where
  # silence leaves them looking at nothing.
  it "stays quiet when the card went up, and speaks when it couldn't" do
    create(:list_item, list: list, name: "Oat milk")
    expect(tool[:receipt].call(execute, ctx)).to be_nil

    list.list_items.destroy_all
    result = execute
    expect(result[:shown]).to eq(0)
    expect(tool[:receipt].call(result, ctx)).to include("Nothing on Groceries")
  end

  it "refuses a list they don't have" do
    expect { execute(name: "wine cellar") }.to raise_error(/no list matching/)
  end
end
