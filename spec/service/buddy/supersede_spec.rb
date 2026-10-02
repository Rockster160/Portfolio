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

  # A level-3 tool: something that waits on a tap. Chore and agenda writes have
  # both moved to level 2 and run on arrival, so an edit to a logged event is
  # the cheapest thing left that still holds.
  def gate_call(call_id, name)
    ActionEvent.find_or_create_by!(user: user, name: name) { |e| e.timestamp = Time.current }
    { name: :edit_event, call_id: call_id, arguments: { "event" => name, "notes" => "from #{call_id}" } }
  end

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

  # Prod 1164/1166, 1 Oct. iCapital confirmed a Zoom interview for Mon Oct 5 at
  # 9am; at 3:07pm they wrote "Please ignore the last confirmation" and gave Wed
  # Oct 7 at 8am instead. The Oct 7 note was filed and the calendar is right,
  # but the Oct 5 CARD stayed pending - one tap away from booking a slot that
  # had been called off.
  #
  # Three of these: iCapital again on 21 Sep ("Please disregarded the last
  # email", two minutes behind the first) and KODE Health on 25 Sep. Two put the
  # cancelled slot on the calendar, agenda items 1159 and 1174, both deleted by
  # hand.
  describe "a rescheduled interview" do
    # `job_search` is owner-only (Buddy::Features::OWNER_ONLY), so a fixture
    # account cannot reach add_job_note at all - the call is dropped before a
    # row is ever built.
    let(:user) { User.me }
    let!(:job) { user.job_applications.create!(company: "iCapital", role: "Full Stack Engineer") }

    # `User.me` is ONE object for the whole process (`@@me ||=`), so the grant
    # outlives this example IN MEMORY even though its row is rolled back with
    # the transaction. Left dirty it hands the next spec a feature its account
    # should not have. Put back by assignment, not a write - the row never
    # needed changing.
    around { |example|
      held = Array(user.buddy_features).dup
      user.grant_buddy_features!(:job_search)
      example.run
      user.buddy_features = held
    }

    def book(call_id, at)
      turn!("job mail", [{
        name:      :add_job_note,
        call_id:   call_id,
        arguments: {
          "company"      => "iCapital",
          "tag"          => "scheduled",
          "note"         => "You are confirmed for your Zoom Interview on #{at}.",
          "follow_up_at" => at,
        },
      }])
    end

    def note(call_id, body)
      turn!("job mail", [{
        name:      :add_job_note,
        call_id:   call_id,
        arguments: { "company" => "iCapital", "tag" => "note", "note" => body },
      }])
    end

    it "retires the booking it corrects" do
      book("c1", "2026-10-05T09:00:00-06:00")
      book("c2", "2026-10-07T08:00:00-06:00")

      first, second = checklists.to_a
      expect(rows(first).first["status"]).to eq("superseded")
      expect(rows(second).first["status"]).to eq("pending")
    end

    # Keyed on the JOB, because the words are the one thing a reschedule is
    # certain to change - a key built from them can never match the booking it
    # replaces.
    it "keys a booking on the job rather than on what the mail said" do
      book("c1", "2026-10-05T09:00:00-06:00")

      expect(rows(checklists.first).first["merge_key"]).to eq("add_job_note:scheduled:job:#{job.id}")
    end

    # Everything that is not a booking stays keyed on its words, so two
    # different beats on one row never collapse into one.
    it "leaves a plain note keyed on what it says" do
      note("c1", "Thanks for the update.")
      note("c2", "Sending availability now.")

      first, second = checklists.to_a
      expect(rows(first).first["status"]).to eq("pending")
      expect(rows(second).first["status"]).to eq("pending")
    end

    # The half that must NOT happen. A tapped booking has written a note and a
    # calendar entry, and the replacement does not own either of them - the
    # untick on that row is the only way to take them back.
    it "leaves a booking that was already tapped standing, undo and all" do
      book("c1", "2026-10-05T09:00:00-06:00")
      action = checklists.first
      action.apply_decision!(value: [rows(action).first["id"]])
      Buddy::ProposalExecutor.perform(action.id)
      expect(rows(action).first["status"]).to eq("executed")

      book("c2", "2026-10-07T08:00:00-06:00")

      filed = rows(checklists.first).first
      expect(filed["status"]).to eq("executed")
      expect(filed["undoable"]).not_to be(false)
      expect(job.notes.where(tag: :scheduled).count).to eq(1)
    end
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
      # `target_count` is what says out loud that this one is meant to be done
      # several times a day - and it is what keeps the duplicate guard off it
      # (see Buddy::ChoreDuplicate).
      chore = create(:chore, created_by_user: user, name: "8oz Water", target_count: 4)
      2.times { |i|
        turn!("drank water", [{ name: :complete_chore, call_id: "w#{i}", arguments: { "chore" => "water" } }])
      }

      expect(rows(checklists.first).first["status"]).to eq("executed")
      expect(rows(checklists.first).first["merge_key"]).to be_nil
      expect(ChoreCompletion.where(chore: chore).count).to eq(2)
    end

    it "keeps rows from a tool that never said what makes two calls the same" do
      2.times { |i| turn!("fix the costco run", [gate_call("a#{i}", "Costco Run")]) }

      # edit_event declares no merge_key, so every call is its own thing and
      # nothing gets retired out from under the person.
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
      turn!("the prompt, then fix laundry", [
        answer_call("c1", "Rockster160"),
        gate_call("c2", "Laundry"),
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
