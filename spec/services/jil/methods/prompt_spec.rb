RSpec.describe Jil::Methods::Prompt do
  include ActiveJob::TestHelper

  let(:execute) { Jil::Executor.call(user, code, input_data) }
  let(:user) { User.me }
  let(:code) {
    <<-JIL
      wa0d7 = Prompt.create("Good morning! How was your sleep?", "", {
        t33bc = PromptQuestion.scale("Sleep Quality", 0, 100, 50)::PromptQuestion
        s5a6a = PromptQuestion.scale("Sleep Length", 0, 100, 50)::PromptQuestion
      }, false)::Prompt
    JIL
  }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  # [Prompt]
  #   #find(String|Numeric)
  #   #all("complete?" Boolean(false))::Array
  #   #create("Title" TAB String BR "Params" TAB Hash? BR "Data" TAB Hash? BR "Questions" content(PromptQuestion))
  #   .update("Title" TAB String BR "Params" TAB Hash? BR "Data" TAB Hash? BR "Questions" content(PromptQuestion))::Boolean
  #   .destroy::Boolean
  #   .deliver::Boolean
  # [PromptQuestion]
  #   #text(String:"Question Text" BR "Default" String)
  #   #checkbox(String:"Question Text" BR "Default" Boolean)
  #   #choices(String:"Question Text" content(String))
  #   #scale(String:"Question Text" BR Numeric?:"Min" Numeric?:"Max" Numeric?:"Default")

  describe "#create" do
    it "creates a PromptQuestion" do
      expect_successful_jil
      prompt = Prompt.last
      expect(ctx.dig(:vars, :t33bc)).to match_hash({
        class: :PromptQuestion,
        value: {
          type:     :scale,
          question: "Sleep Quality",
          min:      0,
          max:      100,
          default:  50,
        },
      })
      found = ctx.dig(:vars, :wa0d7, :value)
      expect(found).to be_a(::Prompt)
      expect(found.id).to eq(prompt.id)
      expect(found.question).to eq("Good morning! How was your sleep?")
      expect(found.params).to be_nil
      expect(found.options).to eq([
        { "type" => "scale", "question" => "Sleep Quality", "min" => 0, "max" => 100, "default" => 50 },
        { "type" => "scale", "question" => "Sleep Length", "min" => 0, "max" => 100, "default" => 50 },
      ])
      expect(found.response).to be_nil
      expect(ctx[:output]).to eq([])
    end
  end

  # The Buddy thread is where prompts are answered, unless the prompt says it
  # stays on /prompts.
  describe "#create in the Buddy thread" do
    let!(:conversation) { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }
    let(:data) { %(Hash.keyval("action_event_id", 7)::Hash) }
    let(:code) {
      <<-JIL
        params = #{data}
        p = Prompt.create("How was your shower, sir?", params, {
          q = PromptQuestion.text("Notes", "")::PromptQuestion
        }, true)::Prompt
      JIL
    }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow_any_instance_of(described_class).to receive(:broadcast_push)
      allow(WebPushNotifications).to receive(:send_to_byte)
    end

    def forms
      ByteAction.where(byte_conversation: conversation, tool_name: Buddy::FormAction::TOOL_NAME)
    end

    it "posts it as a form, which pushes instead of the /prompts link" do
      expect_any_instance_of(described_class).not_to receive(:broadcast_push)
      expect_successful_jil

      expect(forms.map { |a| a.tool_input.dig("payload", "id") }).to eq([Prompt.last.id])
      expect(WebPushNotifications).to have_received(:send_to_byte)
    end

    context "when it is kept in the app" do
      let(:data) {
        <<~JIL.strip
          Hash.new({
              k1 = Keyval.new("action_event_id", 7)::Keyval
              k2 = Keyval.new("app_only", true)::Keyval
            })::Hash
        JIL
      }

      it "stays out of the thread and pushes the /prompts link" do
        expect_any_instance_of(described_class).to receive(:broadcast_push)
        expect_successful_jil

        expect(forms).to be_empty
        expect(WebPushNotifications).not_to have_received(:send_to_byte)
      end
    end
  end

  describe "#deliver" do
    let!(:conversation) { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }
    let(:code) {
      <<-JIL
        asks = Prompt.all(false)::Array
        open = asks.first()::Prompt
        again = open.deliver()::Boolean
      JIL
    }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
    end

    def forms
      ByteAction.where(byte_conversation: conversation, tool_name: Buddy::FormAction::TOOL_NAME)
    end

    it "asks again in the thread, in place of the form already there" do
      prompt = user.prompts.create!(question: "Sick check-in", options: [{ type: :text, question: "Notes" }])
      Buddy::PromptDelivery.post!(user, prompt)
      first = forms.sole

      expect_successful_jil
      expect(ctx.dig(:vars, :again, :value)).to be(true)
      expect(forms.where.not(id: first.id).sole.tool_input.dig("payload", "id")).to eq(prompt.id)
      expect(first.reload).not_to be_pending
    end

    context "when it was already answered" do
      let(:answered) {
        user.prompts.create!(
          question: "Sick check-in",
          options:  [{ type: :text, question: "Notes" }],
          response: { "Notes" => "fine" },
        )
      }
      let(:code) {
        <<-JIL
          open = Prompt.find(#{answered.id})::Prompt
          again = open.deliver()::Boolean
        JIL
      }

      it "does nothing" do
        expect_successful_jil
        expect(ctx.dig(:vars, :again, :value)).to be(false)
        expect(forms).to be_empty
      end
    end
  end

  describe "#chips" do
    let(:code) {
      <<-JIL
        colors = Hash.new({
          yesColor = Keyval.new("Yes", "#16A34A")::Keyval
          badColor = Keyval.new("No", "red")::Keyval
        })::Hash
        q = PromptQuestion.chips("Washed it?", {
          a = String.new("Yes")::String
          b = String.new("No")::String
          c = String.new("Rockster160")::String
        }, "Yes", colors)::PromptQuestion
      JIL
    }

    it "carries a color for each chip that has one" do
      expect_successful_jil
      expect(ctx.dig(:vars, :q, :value).to_h.symbolize_keys).to eq(
        type:     :chips,
        question: "Washed it?",
        choices:  ["Yes", "No", "Rockster160"],
        default:  "Yes",
        colors:   { "Yes" => "#16A34A", "Rockster160" => "#0160FF" },
      )
    end
  end

  describe "#search" do
    let(:code) {
      <<-JIL
        q = PromptQuestion.search("Which print?", "action_events:print", "{notes}", "{timestamp}", true, false)::PromptQuestion
        b = PromptQuestion.search("Which?", "contacts:")::PromptQuestion
      JIL
    }

    it "carries its search, its templates, and how many it answers with" do
      expect_successful_jil
      expect(ctx.dig(:vars, :q, :value).to_h.symbolize_keys).to eq(
        type:     :search,
        question: "Which print?",
        query:    "action_events:print",
        title:    "{notes}",
        detail:   "{timestamp}",
        multiple: true,
      )
      expect(ctx.dig(:vars, :b, :value).to_h.symbolize_keys).to eq(
        type: :search, question: "Which?", query: "contacts:",
      )
    end

    it "passes validation" do
      expect { Jil::Validator.validate!(code) }.not_to raise_error
    end
  end

  describe "#hint" do
    let(:code) {
      <<-JIL
        p = Prompt.create("How many calories was toast?", "", {
          c = PromptQuestion.text("Calories", "170")::PromptQuestion
          h = PromptQuestion.hint("Two slices white toast - 170")::PromptQuestion
        }, false)::Prompt
      JIL
    }

    it "sits in the question list as text with no default to post" do
      expect_successful_jil
      expect(Prompt.last.options.last).to eq({ "type" => "hint", "question" => "Two slices white toast - 170" })
    end
  end

  describe "a check-in's questions" do
    let(:code) {
      <<~'JIL'
        flagColors = Hash.new({
          flagRed = Keyval.new("🩸 Period", "#e5484d")::Keyval
        })::Hash
        flags = PromptQuestion.toggles("Something happened", {
          flagOne = String.new("🩸 Period")::String
          flagTwo = String.new("💥 Meltdown")::String
        }, flagColors)::PromptQuestion
        flagLabels = Hash.new({
          labelRabbit = Keyval.new("🩸 Period", "🐇")::Keyval
        })::Hash
        labeled = PromptQuestion.toggles("Something happened", {
          labelOne = String.new("🩸 Period")::String
          labelTwo = String.new("💥 Meltdown")::String
        }, flagColors, flagLabels)::PromptQuestion
        moved = PromptQuestion.scale("Feeling", 0, 10, 6, true)::PromptQuestion
      JIL
    }

    it "shows a toggle as its label while answering with its choice" do
      expect_successful_jil
      expect(ctx.dig(:vars, :flags, :value).symbolize_keys).not_to have_key(:labels)
      expect(ctx.dig(:vars, :labeled, :value).symbolize_keys).to include(
        choices: ["🩸 Period", "💥 Meltdown"],
        labels:  { "🩸 Period" => "🐇" },
      )
    end

    it "asks flags as toggles, answered like choices, and a slider only if moved" do
      expect_successful_jil
      expect(ctx.dig(:vars, :flags, :value)).to match_hash({
        type:     :choices,
        style:    :toggles,
        question: "Something happened",
        selected: [],
        choices:  ["🩸 Period", "💥 Meltdown"],
        colors:   { "🩸 Period" => "#e5484d" },
      })
      expect(ctx.dig(:vars, :moved, :value).symbolize_keys).to include(type: :scale, default: 6, optional: true)
    end
  end
end
