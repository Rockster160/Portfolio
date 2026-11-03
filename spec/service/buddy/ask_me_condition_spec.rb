require "rails_helper"

# `ask_me` is a FORM rather than a relay: the queued steps behind it are held
# until the person answers, and `continue_if` decides whether they run.
RSpec.describe "Buddy ask_me continue_if" do
  let(:user)   { create(:user) }
  let!(:todo)  { create(:list, user: user, name: "Todo") }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    convo.update_columns(buddy_theme: "byte")
  }

  def ask(continue_if: "yes")
    args = { "question" => "Order the syrup?", "var" => "mine" }
    args["continue_if"] = continue_if if continue_if
    inbound = convo.byte_messages.create!(
      user: user, direction: :outbound, state: :sent, body: "Ask me whether to order syrup, and if yes add it to my list",
    )
    Buddy::GPT::Turn.run!(inbound, client: FakeBuddyClient.new([
      {
        tool_calls: [
          { name: :ask_me, call_id: "c1", arguments: args },
          {
            name:      :add_list_item,
            call_id:   "c2",
            arguments: { "list" => "Todo", "item" => "Syrup" },
          },
        ],
      },
      { text: "Asked." },
    ]))
  end

  def form
    ByteAction.where(user_id: user.id, tool_name: Buddy::FormAction::TOOL_NAME).order(:id).last
  end

  def answer!(text)
    Buddy::FormAction.submit!(form, values: { "answer" => text })
  end

  def items
    ListItem.joins(:list).where(lists: { id: todo.id })
  end

  it "holds the add until the answer, then adds it on a yes" do
    ask

    expect(items).to be_empty
    expect(form).to be_present

    answer!("yes")

    expect(items.pluck(:name)).to eq(["Syrup"])
  end

  it "adds nothing on a no" do
    ask
    answer!("no")

    expect(items).to be_empty
  end

  it "still adds it either way when no condition was given" do
    ask(continue_if: nil)
    answer!("no")

    expect(items.pluck(:name)).to eq(["Syrup"])
  end
end
