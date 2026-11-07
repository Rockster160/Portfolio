require "rails_helper"

# Editable forms in the thread: Buddy fills one in, the person corrects whatever
# is wrong, and sending it runs the tool. The whole reason guessing is safe.
RSpec.describe Buddy::FormAction do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(::Jil).to receive(:trigger).and_return(true)
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
    it "opens filled in on its own message, carrying every field and what the server rebuilds from", :aggregate_failures do
      prompt = calorie_prompt
      action = post_form(prompt, { "Calories" => "240" })

      meta = form_meta(action)
      expect(meta["fields"].to_h { |f| [f["key"], f["value"]] }).to eq("Notes" => "cafe protein shake", "Calories" => "240")
      expect(meta["status"]).to eq("pending")
      expect(action.byte_message.body).to eq(prompt.question)
      # Its own message, so a checklist can coexist with it.
      expect(action.byte_message.metadata["tool_name"]).to eq("buddy_form")
      expect(action.expires_at).to be > 1.day.from_now
      # What the SERVER needs to rebuild, not the rendered fields.
      expect(action.tool_input["tool_name"]).to eq("answer_prompt")
      expect(action.tool_input["payload"]["id"]).to eq(prompt.id)
    end

    it "carries a field Buddy could not fill" do
      expect(form_meta(post_form(calorie_prompt, {}))["fields"].pluck("key")).to eq(["Notes", "Calories"])
    end
  end

  describe "sending it" do
    it "writes the person's correction, ignores unknown fields, and settles as a read-only summary", :aggregate_failures do
      prompt = calorie_prompt
      action = post_form(prompt, { "Calories" => "240" })

      result = described_class.submit!(action, values: {
        "Notes" => "cafe protein shake", "Calories" => "180", "Protein" => "30"
      })

      expect(result[:ok]).to be(true)
      expect(prompt.reload.response).to eq("Notes" => "cafe protein shake", "Calories" => "180")
      expect(::Jil).to have_received(:trigger).with(user, :prompt, anything).at_least(:once)
      meta = form_meta(action)
      expect(meta["status"]).to eq("submitted")
      expect(meta["fields"].find { |f| f["key"] == "Calories" }["value"]).to eq("180")

      # Sends once, however many times the button is tapped.
      expect(described_class.submit!(action, values: { "Notes" => "x", "Calories" => "1" })[:ok]).to be(false)
      expect(prompt.reload.response["Calories"]).to eq("180")
    end

    # Free text, numbers and multi-picks may go in empty, the way the page lets
    # them: a shower's "With" is usually blank.
    it "sends a form with its text left blank" do
      prompt = calorie_prompt
      action = post_form(prompt, {})

      result = described_class.submit!(action, values: { "Notes" => "", "Calories" => "" })

      expect(result[:ok]).to be(true)
      expect(prompt.reload.response).to be_a(Hash)
      expect(prompt.response["Notes"]).to be_blank
    end

    it "refuses a form missing a pick and keeps it live so they can fix it" do
      prompt = Prompt.create!(user: user, answer_type: :single, question: "Washed it?", options: [
        { "type" => "chips", "question" => "Washed", "choices" => ["Yes", "No"] },
        { "type" => "text", "default" => "", "question" => "With" },
        { "type" => "choices", "question" => "Medicine taken", "choices" => ["Multi", "Ibu"] },
      ])
      action = post_form(prompt, {})

      result = described_class.submit!(action, values: { "Washed" => "", "With" => "", "Medicine taken" => [] })

      expect(result[:ok]).to be(false)
      expect(result[:errors].length).to eq(1)
      expect(result[:errors].join).to include("Washed")
      expect(action.reload).to be_pending
      expect(prompt.reload.response).to be_nil
    end

    it "refuses one that has expired" do
      action = post_form(calorie_prompt, { "Calories" => "240" })
      action.update_columns(expires_at: 1.minute.ago)

      result = described_class.submit!(action, values: { "Notes" => "x", "Calories" => "240" })

      expect(result[:ok]).to be(false)
      expect(action.reload).to be_pending
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

  # A form's footer is a list of actions, not a lone Send. The other buttons run
  # a tool of their OWN against the payload the form was posted with, which is
  # what lets a Skip exist on a form whose every field is required.
  describe "the other buttons" do
    it "puts the primary last, so it lands on the right" do
      expect(form_meta(post_form(calorie_prompt, {}))["actions"].pluck("key")).to eq(%w[skip submit])
    end

    it "skips without reading a field, tells listeners it was skipped, and closes the form", :aggregate_failures do
      fired = []
      allow(::Jil).to receive(:trigger) { |_user, scope, payload|
        fired << [scope, payload.try(:[], :status) || payload.try(:status)]
        true
      }
      prompt = calorie_prompt
      action = post_form(prompt, { "Calories" => "240" })

      # Every field empty — the submit would refuse this outright.
      result = described_class.submit!(action, values: {}, key: "skip")

      expect(result[:ok]).to be(true)
      expect(Prompt.find_by(id: prompt.id)).to be_nil
      expect(fired).to include([:prompt, :skip])
      expect(fired.map(&:last)).not_to include(:complete)

      meta = form_meta(action)
      expect(meta["status"]).to eq("submitted")
      expect(meta["decided"]).to eq("skip")
      # The values were never sent, so they still show Buddy's guess.
      expect(meta["fields"].find { |f| f["key"] == "Calories" }["value"]).to eq("240")

      expect(described_class.submit!(action, values: { "Notes" => "x", "Calories" => "240" })[:ok]).to be(false)
    end

    it "refuses a button this form was never posted with" do
      prompt = calorie_prompt
      action = post_form(prompt, { "Calories" => "240" })

      result = described_class.submit!(action, values: {}, key: "delete_everything")

      expect(result[:ok]).to be(false)
      expect(action.reload).to be_pending
      expect(Prompt.find_by(id: prompt.id)).to be_present
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

    it "rejects a value outside the choices or a scale's range rather than inventing one", :aggregate_failures do
      expect(collect(:select, "Zebra", choices: %w[Cat Dog]).last).to be_present
      expect(collect(:scale, "400", min: 0, max: 100).last).to be_present
      expect(collect(:scale, "40", min: 0, max: 100).last).to be_empty
    end

    it "keeps a chips field and its colors, and takes only one of the chips", :aggregate_failures do
      field = {
        key: "Who did it?", type: :chips, choices: %w[Rockster160 Alchemibluum],
        colors: { Rockster160: "#0160FF" },
      }

      expect(described_class.normalize([field]).sole).to include(
        type: :chips, choices: %w[Rockster160 Alchemibluum], colors: { "Rockster160" => "#0160FF" },
      )
      expect(described_class.collect([field], { "Who did it?" => "alchemibluum" })).to eq(
        [{ "Who did it?" => "Alchemibluum" }, []],
      )
      expect(described_class.collect([field], { "Who did it?" => "Eve" }).last.length).to eq(1)
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
