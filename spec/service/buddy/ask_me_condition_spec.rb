require "rails_helper"

# The same "if they say yes" gate, on the other kind of question.
#
# `ask_me` is a FORM rather than a relay — it asks the person in front of you
# instead of someone else — and it released its queue on submit with no more
# regard for the answer than the relay path had. "Ask me whether to order it,
# and if yes put it on the list" put it on the list either way.
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

  def last_said
    convo.byte_messages.where(direction: :inbound).order(:created_at).last.body
  end

  it "asks before it adds anything" do
    ask

    expect(items).to be_empty
    expect(form).to be_present
  end

  it "adds it on a yes" do
    ask
    answer!("yes")

    expect(items.pluck(:name)).to eq(["Syrup"])
  end

  it "adds nothing on a no" do
    ask
    answer!("no")

    expect(items).to be_empty
  end

  # Nobody else was involved, so the line speaks to them directly.
  it "says what it didn't do, in the second person" do
    ask
    answer!("no")

    expect(last_said).to eq("You said no, so I didn't go on to Syrup.")
  end

  it "still adds it either way when no condition was given" do
    ask(continue_if: nil)
    answer!("no")

    expect(items.pluck(:name)).to eq(["Syrup"])
  end
end
