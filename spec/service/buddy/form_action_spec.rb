require "rails_helper"

# Editable forms in the thread: Buddy fills one in, the person corrects whatever
# is wrong, and sending it runs the tool. The whole reason guessing is safe.
RSpec.describe Buddy::FormAction do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(::Jil).to receive(:trigger).and_return(true)
    allow(::WebPushNotifications).to receive(:update_count)
  }

  # "How many calories was cafe protein shake?" — Notes arrives filled, Calories
  # is the one Buddy has to supply.
  def calorie_prompt
    Prompt.create!(user: user, answer_type: :single, question: "How many calories was cafe protein shake?", options: [
      { "type" => "text", "default" => "cafe protein shake", "question" => "Notes" },
      { "type" => "text", "default" => "", "question" => "Calories" },
    ])
  end

  def post_form(prompt, answers)
    described_class.post!(
      user:         user,
      conversation: convo,
      tool:         Buddy::Tools[:answer_prompt],
      payload:      { id: prompt.id, answers: answers },
    )
  end

  def form_meta(action)
    action.byte_message.reload.metadata["form"]
  end

  describe "posting one" do
    it "opens already filled in with what Buddy worked out" do
      prompt = calorie_prompt
      action = post_form(prompt, { "Calories" => "240" })

      values = form_meta(action)["fields"].to_h { |f| [f["key"], f["value"]] }
      expect(values).to eq("Notes" => "cafe protein shake", "Calories" => "240")
      expect(action.byte_message.body).to eq(prompt.question)
    end

    it "carries every field, including the ones Buddy could not fill" do
      action = post_form(calorie_prompt, {})

      keys = form_meta(action)["fields"].pluck("key")
      expect(keys).to eq(["Notes", "Calories"])
      expect(form_meta(action)["status"]).to eq("pending")
    end

    it "lands on its own message so a checklist can coexist with it" do
      action = post_form(calorie_prompt, {})

      expect(action.byte_message.metadata["tool_name"]).to eq("buddy_form")
      expect(action.expires_at).to be > 1.day.from_now
    end

    it "stores what the SERVER needs to rebuild, not the rendered fields" do
      prompt = calorie_prompt
      action = post_form(prompt, { "Calories" => "240" })

      expect(action.tool_input["tool_name"]).to eq("answer_prompt")
      expect(action.tool_input["payload"]["id"]).to eq(prompt.id)
    end
  end

  describe "sending it" do
    it "writes the response and marks the prompt answered" do
      prompt = calorie_prompt
      action = post_form(prompt, { "Calories" => "240" })

      result = described_class.submit!(action, values: { "Notes" => "cafe protein shake", "Calories" => "240" })

      expect(result[:ok]).to be(true)
      expect(prompt.reload.response).to eq("Notes" => "cafe protein shake", "Calories" => "240")
      expect(::Jil).to have_received(:trigger).with(user, :prompt, anything).at_least(:once)
    end

    it "takes the person's correction over what Buddy guessed" do
      prompt = calorie_prompt
      action = post_form(prompt, { "Calories" => "240" })

      described_class.submit!(action, values: { "Notes" => "cafe protein shake", "Calories" => "180" })

      expect(prompt.reload.response["Calories"]).to eq("180")
    end

    it "re-renders as a read-only summary of what was actually sent" do
      action = post_form(calorie_prompt, { "Calories" => "240" })

      described_class.submit!(action, values: { "Notes" => "cafe protein shake", "Calories" => "180" })

      meta = form_meta(action)
      expect(meta["status"]).to eq("submitted")
      expect(meta["receipt"]).to eq("Answered it ✓")
      expect(meta["fields"].find { |f| f["key"] == "Calories" }["value"]).to eq("180")
    end

    it "refuses a half-filled form and keeps it live so they can fix it" do
      prompt = calorie_prompt
      action = post_form(prompt, {})

      result = described_class.submit!(action, values: { "Notes" => "cafe protein shake", "Calories" => "" })

      expect(result[:ok]).to be(false)
      expect(result[:errors].join).to include("Calories needs a value")
      expect(action.reload).to be_pending
      expect(prompt.reload.response).to be_nil
    end

    it "ignores a field the form does not have" do
      prompt = calorie_prompt
      action = post_form(prompt, { "Calories" => "240" })

      described_class.submit!(action, values: {
        "Notes" => "cafe protein shake", "Calories" => "240", "Protein" => "30"
      })

      expect(prompt.reload.response.keys).to contain_exactly("Notes", "Calories")
    end

    it "sends once, however many times the button is tapped" do
      prompt = calorie_prompt
      action = post_form(prompt, { "Calories" => "240" })
      values = { "Notes" => "shake", "Calories" => "240" }

      first  = described_class.submit!(action, values: values)
      second = described_class.submit!(action, values: values)

      expect(first[:ok]).to be(true)
      expect(second[:ok]).to be(false)
      expect(second[:errors].join).to include("already been sent")
    end

    it "refuses one that has expired" do
      action = post_form(calorie_prompt, { "Calories" => "240" })
      action.update_columns(expires_at: 1.minute.ago)

      result = described_class.submit!(action, values: { "Notes" => "x", "Calories" => "240" })

      expect(result[:ok]).to be(false)
      expect(result[:errors].join).to include("expired")
    end

    it "rebuilds from the tool, so a prompt answered elsewhere cannot be resubmitted" do
      prompt = calorie_prompt
      action = post_form(prompt, { "Calories" => "240" })
      prompt.update!(response: { "Calories" => "180" })

      result = described_class.submit!(action, values: { "Notes" => "x", "Calories" => "240" })

      expect(result[:ok]).to be(false)
      expect(prompt.reload.response["Calories"]).to eq("180")
    end
  end

  describe Buddy::FormFields do
    def collect(type, raw, **extra)
      fields = [{ key: "F", label: "F", type: type, **extra }]
      described_class.collect(fields, { "F" => raw })
    end

    it "posts each type in the shape the app's own form would" do
      expect(collect(:datetime, "2026-07-30 09:15").first["F"]).to eq("2026-07-30T09:15")
      expect(collect(:number, "12.0").first["F"]).to eq("12")
      expect(collect(:checkbox, "yes").first["F"]).to eq("true")
      expect(collect(:choices, "a, b", choices: %w[A B C]).first["F"]).to eq(%w[A B])
      expect(collect(:color, "#4488FF").first["F"]).to eq("#4488ff")
    end

    it "rejects a value outside the choices rather than inventing one" do
      _values, errors = collect(:select, "Zebra", choices: %w[Cat Dog])
      expect(errors.join).to include("isn't one of the options")
    end

    it "keeps a scale inside its range" do
      _values, errors = collect(:scale, "400", min: 0, max: 100)
      expect(errors.join).to include("between 0 and 100")
    end

    it "carries hidden fields through untouched, since the person never sees them" do
      values, errors = described_class.collect(
        [{ key: "src", type: :hidden, value: "buddy" }],
        { "src" => "tampered" },
      )
      expect(values).to eq("src" => "buddy")
      expect(errors).to be_empty
    end

    it "lets an optional field stay empty" do
      _values, errors = collect(:text, "", required: false)
      expect(errors).to be_empty
    end
  end
end
