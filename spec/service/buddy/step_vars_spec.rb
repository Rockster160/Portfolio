require "rails_helper"

# A sequence that asks something and then uses the answer: a step captures a
# value under a var, and a later step's `{{var}}` is filled in when its gate
# releases.
RSpec.describe "Buddy step variables" do
  let(:user)       { create(:user) }
  let(:partner)    { create(:user) }
  let(:her)        { partner.username } # first_name == username for factory users
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:convo)     {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }
  let!(:her_convo) {
    partner.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(::Jil).to receive(:trigger).and_return(true)
    # Picking a question back up seeds a real Buddy turn, and Sidekiq runs
    # inline here. We assert on the seed that gets written, not on the reply.
    allow(BuddyDeliverWorker).to receive(:perform_async)
    ChoreHouseholdMembership.create!(chore_household: household, user: partner, role: :member)
    user.update!(chore_household_id: household.id)
    partner.update!(chore_household_id: household.id)
  }

  def message!
    convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok", delivered_at: Time.current)
  end

  def build!(markers)
    Buddy::ProposalBuilder.create(user: user, byte_message: message!, markers: markers)
  end

  def ask_me(question, var, choices: nil)
    { tool_name: :ask_me, payload: { question: question, var: var, choices: choices }.compact }
  end

  def ask_her(question, var)
    { tool_name: :ask_partner, payload: { to: her, question: question, await_reply: true, var: var } }
  end

  # The "then do something with it" step. Level 1, so it stays where it was put
  # in the sequence rather than being hoisted the way a level-2 row is.
  def tell_her(text)
    { tool_name: :message_partner, payload: { to: her, message: text } }
  end

  def told
    BuddyRelay.notify.order(:id).map(&:body)
  end

  def form_action
    ByteAction.where(byte_conversation: convo, tool_name: Buddy::FormAction::TOOL_NAME).order(:id).last
  end

  def relay_gate
    ByteAction.where(byte_conversation: convo, tool_name: Buddy::ProposalBuilder::RELAY_GATE).order(:id).last
  end

  describe "the token itself" do
    it "fills whole-token, in-sentence and nested references", :aggregate_failures do
      whole, = Buddy::StepVars.fill({ text: "{{picked}}" }, { "picked" => %w[a b] })
      sentence, = Buddy::StepVars.fill({ text: "we picked {{picked}} tonight" }, { "picked" => %w[a b] })
      nested, = Buddy::StepVars.fill({ args: { meal: "{{mine}}" } }, { "mine" => "curry" })

      expect(whole[:text]).to eq(%w[a b])
      expect(sentence[:text]).to eq("we picked a, b tonight")
      expect(nested[:args][:meal]).to eq("curry")
    end

    it "reports what it couldn't fill rather than substituting something" do
      filled, missing = Buddy::StepVars.fill({ text: "{{nope}}" }, { "yes" => "1" })

      expect(missing).to eq(["nope"])
      expect(filled[:text]).to eq("{{nope}}")
    end
  end

  describe "asking the person" do
    it "holds the steps behind it until they answer, then fills them in" do
      build!([ask_me("Dinner?", "mine"), tell_her("we're having {{mine}}")])

      expect(form_action).to be_present
      expect(told).to be_empty

      Buddy::FormAction.submit!(form_action, values: { "answer" => "curry" })

      expect(told).to eq(["we're having curry"])
    end

    it "renders as a picker when the answer is one of a few things" do
      build!([ask_me("Dinner?", "mine", choices: "tacos, curry")])

      field = form_action.buttons.first
      expect(field["type"]).to eq("select")
      expect(field["choices"]).to eq(%w[tacos curry])
    end

    it "refuses a var name a later step could never reference" do
      ctx = Buddy::ToolContext.new(user, conversation: convo)

      expect {
        Buddy::Tools[:ask_me][:confirm].call({ question: "Dinner?", var: "my dinner" }, ctx)
      }.to raise_error(/usable name/)
    end
  end

  describe "asking someone else" do
    it "parks the rest on their answer and advances once with it, however many times it lands" do
      build!([ask_her("Dinner?", "hers"), tell_her("she wants {{hers}}")])

      expect(relay_gate).to be_present
      expect(told).to be_empty

      relay = BuddyRelay.last
      relay.update!(status: :delivered)
      Buddy::CompanionRelay.record_answer!(relay, "tacos")
      Buddy::CompanionRelay.record_answer!(relay.reload, "tacos")

      expect(told).to eq(["she wants tacos"])
    end

    # An ordinary question is the overwhelming majority, and it must stay
    # exactly as cheap and as immediate as it was.
    it "leaves a question nothing is waiting on alone" do
      build!([{ tool_name: :ask_partner, payload: { to: her, question: "Dinner?" } }, tell_her("asked her")])

      expect(relay_gate).to be_nil
      expect(told).to eq(["asked her"])
    end

    # An awaited question still promises a pick-up, so the answer comes back
    # to Buddy as a turn.
    describe "awaited with nothing queued behind it" do
      it "holds a gate and hands the answer to Buddy as one hidden turn", :aggregate_failures do
        build!([ask_her("Want to plunge tomorrow?", "hers")])
        expect(relay_gate).to be_present

        relay = BuddyRelay.last
        relay.update!(status: :delivered)
        Buddy::CompanionRelay.record_answer!(relay, "yes")
        Buddy::CompanionRelay.record_answer!(relay.reload, "yes")

        seeds = convo.byte_messages.where("metadata->>'source' = 'relay_answer'")
        expect(seeds.count).to eq(1)
        expect(seeds.last.body).to include("Want to plunge tomorrow?", "yes", partner.first_name)
        expect(seeds.last.metadata["hidden"]).to be(true)
      end

      # A plain ask is still fire-and-forget — no gate, no extra turn.
      it "doesn't take a turn for a question that never asked to wait" do
        build!([{ tool_name: :ask_partner, payload: { to: her, question: "Dinner?" } }])
        relay = BuddyRelay.last
        relay.update!(status: :delivered)

        Buddy::CompanionRelay.record_answer!(relay, "tacos")

        expect(convo.byte_messages.where("metadata->>'source' = 'relay_answer'")).to be_empty
      end
    end

    it "needs somewhere to put the answer before it will wait for one" do
      ctx = Buddy::ToolContext.new(user, conversation: convo)

      expect {
        Buddy::Tools[:ask_partner][:confirm].call({ to: her, question: "Dinner?", await_reply: true }, ctx)
      }.to raise_error(/needs a `var`/)
    end
  end

  # A question with buttons is the one people actually reach for on a phone, so
  # pausing a sequence has to work the same whether they typed the answer or
  # tapped it. Both ways in funnel through record_answer!, which is why the
  # continuation hangs there rather than on either path.
  describe "asking someone else to pick" do
    def ask_her_to_pick(kind, options, var)
      { tool_name: kind, payload: { to: her, question: "Dinner?", options: options, await_reply: true, var: var } }
    end

    # The path a tap really takes, rather than calling record_answer! directly.
    def tap!(*labels)
      relay  = BuddyRelay.last
      action = ByteAction.where(tool_name: "buddy_relay_answer").order(:id).last
      picked = Array(action.buttons).select { |b| labels.include?(b["label"]) }.map { |b| b["id"].to_i }
      Buddy::CompanionRelay.answer_from_action(action, picked)
      relay
    end

    it "waits on a pick-one, then carries what they tapped" do
      build!([ask_her_to_pick(:ask_partner_choice, "tacos, curry", "hers"), tell_her("she picked {{hers}}")])
      expect(relay_gate).to be_present
      expect(told).to be_empty

      tap!("curry")

      expect(told).to eq(["she picked curry"])
    end

    it "waits on a pick-any, and reads several picks as a list" do
      build!([ask_her_to_pick(:ask_partner_multi, "tacos, curry, pizza", "hers"), tell_her("she picked {{hers}}")])

      tap!("tacos", "pizza")

      expect(told).to eq(["she picked tacos, pizza"])
    end

    it "leaves a pick-one nothing is waiting on immediate" do
      build!([
        { tool_name: :ask_partner_choice, payload: { to: her, question: "Dinner?", options: "tacos, curry" } },
        tell_her("asked her"),
      ])

      expect(relay_gate).to be_nil
      expect(told).to eq(["asked her"])
    end
  end

  describe "the whole dinner sequence" do
    it "asks them, asks her, then sends both on" do
      build!([
        ask_me("Dinner?", "mine"),
        ask_her("Dinner?", "hers"),
        tell_her("mine {{mine}}, hers {{hers}}"),
      ])

      # Nothing but the first question yet — the other two are behind it.
      expect(form_action).to be_present
      expect(relay_gate).to be_nil

      Buddy::FormAction.submit!(form_action, values: { "answer" => "curry" })

      # Her question went out, and the last step is now parked on her reply.
      expect(relay_gate).to be_present
      expect(told).to be_empty

      relay = BuddyRelay.last
      relay.update!(status: :delivered)
      Buddy::CompanionRelay.record_answer!(relay, "tacos")

      expect(told).to eq(["mine curry, hers tacos"])
    end
  end

  describe "a value nothing ever collected" do
    # Never pass the literal token on, and never skip the step in silence.
    it "skips the step and says which value was missing" do
      build!([ask_me("Dinner?", "mine"), tell_her("{{nope}}")])
      Buddy::FormAction.submit!(form_action, values: { "answer" => "curry" })

      expect(told).to be_empty
      expect(convo.byte_messages.last.body).to match(/needed `nope`/)
    end

    # Nothing has been collected at the head of a sequence.
    it "refuses to run a step at the very start that references anything" do
      build!([{ tool_name: :log_event, payload: { name: "{{mine}}" } }])

      expect(ActionEvent.count).to eq(0)
      expect(convo.byte_messages.last.body).to match(/needed `mine`/)
    end

    # Level-2 calls are normally hoisted to the front, since they execute on
    # arrival; one waiting on a value must not be.
    it "keeps a step that's waiting on a value behind the gate that collects it" do
      build!([ask_me("Dinner?", "mine"), { tool_name: :log_event, payload: { name: "{{mine}}" } }])
      expect(ActionEvent.count).to eq(0)

      Buddy::FormAction.submit!(form_action, values: { "answer" => "curry" })

      expect(ActionEvent.pluck(:name)).to eq(["curry"])
    end

    it "still hoists one that isn't waiting on anything" do
      build!([ask_me("Dinner?", "mine"), { tool_name: :log_event, payload: { name: "Snack" } }])

      expect(ActionEvent.pluck(:name)).to eq(["Snack"])
    end

    it "still runs the steps beside it that were fine" do
      build!([ask_me("Dinner?", "mine"), tell_her("{{nope}}"), tell_her("this one's fine")])
      Buddy::FormAction.submit!(form_action, values: { "answer" => "curry" })

      expect(told).to eq(["this one's fine"])
    end
  end

  # A watch's text is a Liquid template rendered when it fires, with the
  # trigger's keys - the same braces as a step reference, owed by nobody here.
  describe "an argument that is a template of its own" do
    let(:remind_when) { Buddy::Tools[:remind_when] }

    it "is not a reference an earlier step owes" do
      payload = { text: "📱 {{ action }} at {{ location }}", trigger: "custom" }

      expect(Buddy::StepVars.references(payload, remind_when)).to be_empty
    end

    it "fills in a value a step did collect, and leaves the rest for the template" do
      filled, missing = Buddy::StepVars.fill({ text: "{{ mine }} at {{ location }}" }, { "mine" => "curry" }, remind_when)

      expect(missing).to be_empty
      expect(filled[:text]).to eq("curry at {{ location }}")
    end

    it "sets the watch with its template intact" do
      text = "📱 {{ action | capitalize }} at {{ location }}"
      build!([{
        tool_name: :remind_when,
        payload:   { trigger: "custom", listener: "travel", when_phrase: "when my phone arrives or leaves", text: text, repeat: true },
      }])

      expect(BuddyWatch.where(user: user).pluck(:trigger_scope, :body)).to eq([["travel", text]])
    end
  end

  describe "giving up on an answer that never comes" do
    it "says what it didn't go on to do, and drops the queue" do
      build!([ask_her("Dinner?", "hers"), tell_her("she wants {{hers}}")])
      relay_gate.update!(expires_at: 1.minute.ago)

      BuddyAwaitSweepWorker.new.perform

      expect(relay_gate.reload).to be_expired
      expect(convo.byte_messages.last.body).to include("#{partner.first_name} never answered")
      expect(told).to be_empty
    end

    it "leaves one that's still waiting alone" do
      build!([ask_her("Dinner?", "hers"), tell_her("she wants {{hers}}")])

      BuddyAwaitSweepWorker.new.perform

      expect(relay_gate.reload).to be_pending
    end
  end

  describe "saving one" do
    def save!(steps)
      Buddy::Routines.sanitize(steps, Buddy::ToolContext.new(user, conversation: convo))
    end

    it "accepts a reference to something an earlier step collects" do
      steps = save!([
        { "tool_name" => "ask_me", "payload" => { "question" => "Dinner?", "var" => "mine" } },
        { "tool_name" => "message_partner", "payload" => { "to" => her, "message" => "{{mine}}" } },
      ])

      expect(steps.length).to eq(2)
    end

    # The compensation for what a placeholder costs: a step holding one can't be
    # resolved at save time, so the ordering is checked instead, hard.
    it "rejects a reference nothing before it collects", :aggregate_failures do
      expect {
        save!([{ "tool_name" => "message_partner", "payload" => { "to" => her, "message" => "{{mine}}" } }])
      }.to raise_error(/nothing before it collects that/)

      expect {
        save!([
          { "tool_name" => "message_partner", "payload" => { "to" => her, "message" => "{{mine}}" } },
          { "tool_name" => "ask_me", "payload" => { "question" => "Dinner?", "var" => "mine" } },
        ])
      }.to raise_error(/nothing before it collects that/)
    end

    it "refuses to store one past the tool either" do
      routine = user.buddy_routines.new(
        name:  "broken",
        steps: [BuddyRoutine.step(:message_partner, { "to" => her, "message" => "{{mine}}" })],
      )

      expect(routine).not_to be_valid
      expect(routine.errors[:steps].join).to match(/nothing before it collects that/)
    end
  end
end
