require "rails_helper"

# Correcting something replaces it. "Add trail mix to Shopping" then "that was
# supposed to be under Costco" should leave ONE live row, not two rows for the
# same item with the older one wrong.
RSpec.describe Buddy::Supersede do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let!(:list)  { create(:list, user: user, name: "Shopping") }
  let!(:costco) { create(:section, list: list, name: "Costco") }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(::Jil).to receive(:trigger).and_return(true)
    allow(::WebPushNotifications).to receive(:update_count)
    allow(AgendaTravelChainSyncWorker).to receive(:perform_async)
    convo.update_columns(buddy_theme: "byte")
  }

  def turn!(body, tool_calls)
    inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
    client  = FakeBuddyClient.new([{ tool_calls: tool_calls }, { text: "Sure." }])
    Buddy::GPT::Turn.run!(inbound, client: client)
  end

  def add_item(call_id, section: nil)
    args = { "list" => "Shopping", "item" => "Trail Mix" }
    args["section"] = section if section
    turn!("add trail mix", [{ name: :add_list_item, call_id: call_id, arguments: args }])
  end

  def checklists
    ByteAction.where(byte_conversation: convo, tool_name: "buddy_proposals").order(:id)
  end

  def rows(action)
    action.reload.buttons
  end

  describe "a corrected list item" do
    it "retires the earlier row and leaves the corrected one live" do
      add_item("c1")
      add_item("c2", section: "Costco")

      first, second = checklists.to_a
      expect(rows(first).first["status"]).to eq("superseded")
      expect(rows(second).first["status"]).to eq("executed")
      expect(rows(second).first["sublabel"]).to include("Costco")
    end

    it "remembers that the retired row had actually run" do
      add_item("c1")
      add_item("c2", section: "Costco")

      expect(rows(checklists.first).first["superseded_from"]).to eq("executed")
    end

    # The real hazard: both rows point at the same ListItem, so undoing the
    # stale one would delete what the corrected one just filed.
    it "takes undo off the retired row" do
      add_item("c1")
      add_item("c2", section: "Costco")

      stale = checklists.first
      expect(rows(stale).first["undoable"]).to be(false)

      Buddy::ProposalExecutor.undo!(stale.id, 1)

      expect(list.list_items.reload.pluck(:name)).to eq(["Trail Mix"])
    end

    it "re-renders the retired row for the client" do
      add_item("c1")
      add_item("c2", section: "Costco")

      buttons = checklists.first.byte_message.reload.metadata["buttons"]
      expect(buttons.first["status"]).to eq("superseded")
    end
  end

  describe "what it leaves alone" do
    it "keeps a different item on the same list" do
      add_item("c1")
      turn!("and bananas", [{ name: :add_list_item, call_id: "c2", arguments: { "list" => "Shopping", "item" => "Bananas" } }])

      expect(rows(checklists.first).first["status"]).to eq("executed")
    end

    # merge_key means "the same thing in one breath", which is not the same as
    # "the same thing forever". A second glass of water an hour later is a
    # second completion, and retiring the first would erase it.
    it "keeps a repeatable action that happens to carry the same merge_key" do
      chore = create(:chore, created_by_user: user, name: "8oz Water")
      2.times { |i|
        turn!("drank water", [{ name: :complete_chore, call_id: "w#{i}", arguments: { "chore" => "water" } }])
      }

      expect(rows(checklists.first).first["status"]).to eq("executed")
      expect(rows(checklists.first).first["merge_key"]).to be_nil
      expect(ChoreCompletion.where(chore: chore).count).to eq(2)
    end

    it "keeps rows from a tool that never said what makes two calls the same" do
      at = Time.current.tomorrow.change(hour: 13)
      2.times { |i|
        turn!("add costco run", [{
          name:      :add_agenda_item,
          call_id:   "a#{i}",
          arguments: { "title" => "Costco Run", "at" => at.iso8601, "kind" => "task" },
        }])
      }

      # add_agenda_item declares no merge_key, so every call is its own thing
      # and nothing gets retired out from under the person.
      expect(rows(checklists.first).first["status"]).to eq("pending")
    end
  end

  describe "a re-asked prompt" do
    let(:prompt) {
      Prompt.create!(user: user, answer_type: :single, question: "Who did: Puppy Down?", options: [
        { "type" => "text", "default" => "", "question" => "Who did it?" },
      ])
    }

    def answer_call(call_id, who)
      { name: :answer_prompt, call_id: call_id, arguments: { "id" => prompt.id, "answers" => { "Who did it?" => who } } }
    end

    it "retires the earlier form so only the corrected one can be sent" do
      turn!("fill the puppy prompt", [answer_call("c1", "Rockster160")])
      turn!("actually that was Chelsea", [answer_call("c2", "Chelsea")])

      forms = ByteAction.where(byte_conversation: convo, tool_name: Buddy::FormAction::TOOL_NAME).order(:id).to_a
      expect(forms.length).to eq(2)
      expect(forms.first).to be_decided
      expect(forms.first.byte_message.reload.metadata.dig("form", "status")).to eq("superseded")
      expect(forms.last).to be_pending

      result = Buddy::FormAction.submit!(forms.first, values: { "Who did it?" => "Rockster160" })
      expect(result[:ok]).to be(false)
    end

    it "moves a queue off the form it retired onto the one that replaced it" do
      turn!("the prompt, then add laundry", [
        answer_call("c1", "Rockster160"),
        {
          name:      :add_agenda_item,
          call_id:   "c2",
          arguments: { "title" => "Laundry", "at" => Time.current.tomorrow.change(hour: 13).iso8601, "kind" => "task" },
        },
      ])
      turn!("actually that was Chelsea", [answer_call("c3", "Chelsea")])

      forms = ByteAction.where(byte_conversation: convo, tool_name: Buddy::FormAction::TOOL_NAME).order(:id).to_a
      expect(forms.first.tool_input["deferred"]).to be_blank
      expect(forms.last.tool_input["deferred"].pluck("kind")).to eq(["rows"])

      Buddy::FormAction.submit!(forms.last, values: { "Who did it?" => "Chelsea" })

      expect(checklists.last.buttons.pluck("label")).to eq(["Laundry"])
    end
  end
end
