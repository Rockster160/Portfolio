require "rails_helper"

# Buddy filling out the app's own Prompt surveys on the person's behalf.
#
# The archetypes here are real shapes pulled from the prompt table, because the
# whole feature turns on telling a load-time DEFAULT apart from an ANSWER, and
# that distinction only makes sense against forms that actually exist.
RSpec.describe "Buddy prompt tools" do
  let(:user) { create(:user) }

  def make_prompt(question:, options:, params: {})
    Prompt.create!(user: user, question: question, options: options, params: params, answer_type: :single)
  end

  # "How many calories was cafe protein shake?" - Notes arrives filled from the
  # item name, Calories is the one thing Buddy has to get from the person.
  def calorie_prompt
    make_prompt(question: "How many calories was cafe protein shake?", options: [
      { "type" => "text", "default" => "cafe protein shake", "question" => "Notes" },
      { "type" => "text", "default" => "", "question" => "Calories" },
    ])
  end

  # "Good morning! How was your sleep?" - seven 0-100 scales that all default to
  # 0. Submitting those defaults logs the worst possible night, which is the
  # single most damaging thing this feature could do.
  def morning_prompt
    scales = ["Sleep Quality", "Sleep Length", "Sleepy | Alert", "Stress | Relaxed"]
    make_prompt(question: "Good morning! How was your sleep?", options: scales.map { |q|
      { "max" => 100, "min" => 0, "type" => "scale", "default" => 0, "question" => q }
    })
  end

  # "Who did: Puppy Up?" - a select with no default next to a datetime that
  # loads with now. One gap, one field already answered.
  def chore_prompt
    make_prompt(question: "Who did: Puppy Up?", options: [
      { "type" => "select", "choices" => %w[Rockster160 Alchemibluum Eve], "default" => "", "question" => "Who did it?" },
      { "type" => "datetime", "default" => "2026-07-29T13:52", "question" => "When?" },
    ])
  end

  # "How was your shower, sir?" - the Duration field does not exist on the row.
  # Jil task 232 computes it and pushes it on at load, so a Buddy that reads
  # `options` directly cannot see it and a Buddy that hydrates can.
  def shower_prompt
    make_prompt(question: "How was your shower, sir?", options: [
      { "type" => "choices", "choices" => ["Washed Hair", "Washed Body", "Shaved Face"], "question" => "actions", "selected" => [] },
      { "type" => "text", "default" => "", "question" => "With" },
    ])
  end

  def hydrates_shower!
    allow(::Jil).to receive(:trigger) { |_u, scope, record|
      next true unless scope == :prompt && record.is_a?(Prompt) && record[:state].to_s == "load"

      record.update!(options: record.options + [
        { "max" => nil, "min" => nil, "step" => nil, "type" => "number", "default" => 29, "question" => "Duration" },
      ])
      true
    }
  end

  def form_for(prompt)
    Buddy::PromptForm.hydrate(prompt, user: user)
  end

  def run(tool_name, payload)
    tool    = Buddy::Tools[tool_name]
    confirm = tool[:confirm].call(payload, Buddy::ToolContext.new(user))
    tool[:execute].call(payload.merge(confirm[:resolved] || {}), Buddy::ToolContext.new(user))
  end

  before {
    allow(::Jil).to receive(:trigger).and_return(true)
    allow(::WebPushNotifications).to receive(:update_count)
  }

  describe Buddy::PromptForm do
    it "treats a prefilled default as an answer and an empty one as a gap" do
      form = form_for(calorie_prompt)

      expect(form.fields.pluck(:question)).to eq(["Notes", "Calories"])
      expect(form.fields.first[:value]).to eq("cafe protein shake")
      expect(form.needs_value).to eq(["Calories"])
    end

    it "treats a scale sitting on its own floor as unanswered, not as a zero" do
      form = form_for(morning_prompt)

      expect(form.needs_value).to contain_exactly("Sleep Quality", "Sleep Length", "Sleepy | Alert", "Stress | Relaxed")
      expect(form.fields.first).to include(type: :scale, min: 0, max: 100)
    end

    it "reads the fields a load listener adds, which are not on the row" do
      hydrates_shower!
      form = form_for(shower_prompt)

      expect(form.fields.pluck(:question)).to include("Duration")
      expect(form.fields.find { |f| f[:question] == "Duration" }[:value]).to eq(29)
      expect(form.needs_value).to match_array(%w[actions With])
    end

    it "carries a hydration failure as the skeleton rather than failing the turn" do
      allow(::Jil).to receive(:trigger).and_raise("jil exploded")
      form = form_for(calorie_prompt)

      expect(form.fields.pluck(:question)).to eq(["Notes", "Calories"])
    end

    it "marks a loaded value as the form's, not the person's, so it can be judged" do
      form = form_for(calorie_prompt)

      expect(form.fields.first).to include(question: "Notes", value: "cafe protein shake", from: :default)
      expect(form.fields.last).not_to have_key(:from)
      expect(form.defaulted).to eq(["Notes"])
    end

    it "marks a value the person already gave as theirs" do
      prompt = calorie_prompt
      prompt.update!(response: { "Calories" => "240" })
      form = form_for(prompt)

      expect(form.fields.last).to include(question: "Calories", value: "240", from: :answer)
      expect(form.defaulted).to eq(["Notes"])
    end

    it "keeps timestamps off the review list, since they record when it happened" do
      # The Jil task that created the prompt wrote this time; it is not a guess
      # to be second-guessed, and inviting a model to "check" it gets it moved to
      # now. Still editable, still overridable — just not offered up.
      form = form_for(chore_prompt)

      expect(form.fields.last).to include(question: "When?", from: :default)
      expect(form.defaulted).to be_empty
    end

    it "still takes an explicit time when the person actually gives one" do
      form     = form_for(chore_prompt)
      response = form.build_response({ "Who did it?" => "Eve", "When?" => "2026-07-29 08:15" })

      expect(response["When?"]).to eq("2026-07-29T08:15")
    end

    it "layers answers over the prefills and leaves the prefills alone" do
      form     = form_for(calorie_prompt)
      response = form.build_response({ "Calories" => "240" })

      expect(response).to eq("Notes" => "cafe protein shake", "Calories" => "240")
      expect(form.missing(response)).to be_empty
    end

    it "matches a question loosely so it need not reproduce the punctuation" do
      form     = form_for(morning_prompt)
      response = form.build_response({ "sleepy alert" => 80 })

      expect(response["Sleepy | Alert"]).to eq("80")
    end

    it "reports what is still empty rather than letting a partial form through" do
      form     = form_for(morning_prompt)
      response = form.build_response({ "Sleep Quality" => 70 })

      expect(form.missing(response)).to contain_exactly("Sleep Length", "Sleepy | Alert", "Stress | Relaxed")
    end

    it "refuses a question that is not on the form" do
      form = form_for(calorie_prompt)

      expect { form.build_response({ "Protein" => "30" }) }.to raise_error(/no field named "Protein"/)
    end

    it "refuses a value the field cannot take" do
      form = form_for(chore_prompt)

      expect { form.build_response({ "Who did it?" => "Chelsea" }) }.to raise_error(/only takes/)
      expect { form.build_response({ "Who did it?" => "rockster160" }) }.not_to raise_error
    end

    it "keeps a scale inside its declared range" do
      form = form_for(morning_prompt)

      expect { form.build_response({ "Sleep Quality" => 400 }) }.to raise_error(/between 0 and 100/)
    end

    it "submits each type in the shape the form posts" do
      prompt = make_prompt(question: "How was it?", options: [
        { "type" => "datetime", "default" => "", "question" => "Timestamp" },
        { "type" => "choices", "choices" => %w[V O H], "question" => "actions", "selected" => [] },
        { "type" => "checkbox", "default" => "false", "question" => "Counted?" },
        { "type" => "textarea", "default" => "", "question" => "Comments" },
      ])
      response = form_for(prompt).build_response({
        "Timestamp" => "2026-07-30 09:15",
        "actions"   => "v, h",
        "Counted?"  => "yep",
        "Comments"  => "  good one  ",
      })

      expect(response["Timestamp"]).to eq("2026-07-30T09:15")
      expect(response["actions"]).to eq(%w[V H])
      expect(response["Counted?"]).to eq("true")
      expect(response["Comments"]).to eq("good one")
    end

    it "keeps hidden fields at their defaults, the way the form submits them" do
      prompt = make_prompt(question: "Dinner?", options: [
        { "question" => "What sounds good?", "type" => "text", "default" => "" },
        { "question" => "src", "type" => "hidden", "default" => "buddy" },
      ])
      form     = form_for(prompt)
      response = form.build_response({ "What sounds good?" => "tacos" })

      expect(response).to eq("What sounds good?" => "tacos", "src" => "buddy")
      expect(form.needs_value).to eq(["What sounds good?"])
      expect(form.summary_lines(response)).to eq(["What sounds good?: tacos"])
    end

    it "reports a prompt whose options are not a question list as unanswerable" do
      prompt = make_prompt(question: "Legacy", options: { "some" => "hash" })

      expect(form_for(prompt).answerable?).to be(false)
    end
  end

  describe "read_prompt" do
    let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

    def read(args)
      JSON.parse(Buddy::GPT::PromptTool.new(user, convo).call(args))
    end

    it "hands back the hydrated fields and names the gaps" do
      hydrates_shower!
      prompt = shower_prompt

      out = read({ "id" => prompt.id })

      expect(out["id"]).to eq(prompt.id)
      expect(out["title"]).to eq("How was your shower, sir?")
      expect(out["fields"].pluck("question")).to include("Duration")
      expect(out["needs_value"]).to contain_exactly("actions", "With")
      # The computed Duration is exactly the kind of value that looks answered
      # and often isn't, so it has to come back flagged for review.
      expect(out["defaulted"]).to eq(["Duration"])
      expect(out["next"]).to include("the form is the ask")
      expect(out["next"]).to include("Having a value is not the same as being correct")
    end

    it "picks the only pending prompt when no id is given" do
      prompt = calorie_prompt

      expect(read({ "id" => nil })["id"]).to eq(prompt.id)
    end

    it "asks which one when several are pending" do
      calorie_prompt
      chore_prompt

      out = read({ "id" => nil })
      expect(out["choose"].length).to eq(2)
      expect(out).not_to have_key("fields")
    end

    it "says so plainly when the id has already been answered" do
      prompt = calorie_prompt
      prompt.update!(response: { "Calories" => "1" })

      expect(read({ "id" => prompt.id })["error"]).to include("no pending prompt")
    end
  end

  describe "answer_prompt" do
    it "submits every field at once and fires the completion trigger" do
      prompt = chore_prompt

      run(:answer_prompt, { id: prompt.id, answers: { "Who did it?" => "Eve" } })

      expect(prompt.reload.response).to eq("Who did it?" => "Eve", "When?" => "2026-07-29T13:52")
      expect(user.prompts.unanswered).to be_empty
      expect(::Jil).to have_received(:trigger).with(user, :prompt, anything).at_least(:once)
    end

    it "refuses to submit while a field is still empty" do
      prompt = morning_prompt
      tool   = Buddy::Tools[:answer_prompt]

      expect {
        tool[:confirm].call({ id: prompt.id, answers: { "Sleep Quality" => 70 } }, Buddy::ToolContext.new(user))
      }.to raise_error(/still needs a value/)
      expect(prompt.reload.response).to be_nil
    end

    it "shows every field it is about to submit on the row" do
      prompt  = calorie_prompt
      tool    = Buddy::Tools[:answer_prompt]
      ctx     = Buddy::ToolContext.new(user)
      confirm = tool[:confirm].call({ id: prompt.id, answers: { "Calories" => "240" } }, ctx)
      label   = tool[:label].call({ id: prompt.id }.merge(confirm[:resolved]), ctx)

      expect(label[:title]).to eq("How many calories was cafe protein shake?")
      expect(label[:sub]).to eq("Notes: cafe protein shake\nCalories: 240")
    end

    it "takes an answers object that arrived as a JSON string" do
      prompt = calorie_prompt
      tool   = Buddy::Tools[:answer_prompt]
      payload, errors = Buddy::Tools.validate_payload(tool, { id: prompt.id, answers: '{"Calories":"240"}' })

      expect(errors).to be_empty
      expect(payload[:answers]).to eq("Calories" => "240")
    end

    it "treats an empty answers object as a missing arg" do
      tool = Buddy::Tools[:answer_prompt]
      _payload, errors = Buddy::Tools.validate_payload(tool, { id: 1, answers: {} })

      expect(errors).to include(/missing required arg :answers/)
    end

    it "no-ops on a prompt that got answered between the proposal and the tap" do
      prompt = calorie_prompt
      tool   = Buddy::Tools[:answer_prompt]
      ctx    = Buddy::ToolContext.new(user)
      confirm = tool[:confirm].call({ id: prompt.id, answers: { "Calories" => "240" } }, ctx)
      prompt.update!(response: { "Calories" => "180" })

      result = tool[:execute].call({ id: prompt.id }.merge(confirm[:resolved]), ctx)

      expect(result[:already]).to be(true)
      expect(prompt.reload.response).to eq("Calories" => "180")
    end

    it "collapses two calls for the same prompt into one row" do
      keys = [7, 7, 8].map { |id| Buddy::Tools[:answer_prompt][:merge_key].call({ id: id }) }

      expect(keys.uniq.length).to eq(2)
    end

    it "drops strict mode on the schema, since the keys are the prompt's own" do
      schema = Buddy::Tools.function_schema(Buddy::Tools[:answer_prompt])

      expect(schema[:strict]).to be(false)
      expect(schema[:parameters][:properties][:answers]).to include(type: :object, additionalProperties: true)
    end
  end

  it "skip_prompt destroys the prompt and fires the skip trigger" do
    prompt = calorie_prompt

    run(:skip_prompt, { id: prompt.id })

    expect(Prompt.find_by(id: prompt.id)).to be_nil
    expect(::Jil).to have_received(:trigger).with(user, :prompt, anything)
  end

  it "lists pending prompts as an index, leaving the real fields to read_prompt" do
    prompt = calorie_prompt

    listed = Buddy::Context.send(:pending_prompts, user)
    expect(listed).to include(hash_including(id: prompt.id, title: prompt.question))
    expect(listed.first[:questions]).to eq(["Notes", "Calories"])
  end

  # The whole loop, as Buddy actually runs it: read the form, fill it, speak.
  describe "over a full turn" do
    let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

    before {
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      convo.update_columns(buddy_theme: "byte")
    }

    def turn(rounds, text:)
      inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: text)
      Buddy::GPT::Turn.run!(inbound, client: FakeBuddyClient.new(rounds))
      convo.byte_messages.where(direction: :inbound).order(:created_at).to_a
    end

    def form_message(messages)
      messages.find { |m| m.metadata["tool_name"] == Buddy::FormAction::TOOL_NAME }
    end

    it "reads the prompt, then posts it as a filled-in form of its own" do
      prompt = chore_prompt

      messages = turn(
        [
          { tool_calls: [{ name: :read_prompt, arguments: { "id" => prompt.id } }] },
          { tool_calls: [{ name: :answer_prompt, arguments: { "id" => prompt.id, "answers" => { "Who did it?" => "Eve" } } }] },
          { text: "Eve took the puppy out - check it over and send it." },
        ],
        text: "eve did puppy up",
      )

      form = form_message(messages)
      values = form.metadata["form"]["fields"].to_h { |f| [f["key"], f["value"]] }
      expect(values["Who did it?"]).to eq("Eve")
      expect(values["When?"]).to eq("2026-07-29T13:52") # the timestamp it was told to leave alone
      expect(messages.first.body).to eq("Eve took the puppy out - check it over and send it.")
      expect(prompt.reload.response).to be_nil # nothing is written until they send
    end

    it "posts the form with the gaps still blank rather than stopping to ask" do
      # The old behaviour was to refuse and ask in prose. With an editable form
      # in front of them, the gaps ARE the ask — and the four blank scales are
      # visible and fillable instead of costing another exchange.
      prompt = morning_prompt

      messages = turn(
        [
          { tool_calls: [{ name: :read_prompt, arguments: { "id" => prompt.id } }] },
          { tool_calls: [{ name: :answer_prompt, arguments: { "id" => prompt.id, "answers" => { "Sleep Quality" => 70 } } }] },
          { text: "Put you at a 70 for quality - drag the rest to wherever they landed." },
        ],
        text: "slept about a 70",
      )

      form = form_message(messages)
      values = form.metadata["form"]["fields"].to_h { |f| [f["key"], f["value"]] }
      expect(values["Sleep Quality"]).to eq("70")
      expect(values["Sleep Length"]).to be_blank
      expect(prompt.reload.response).to be_nil
    end

    it "does not retract the reply just because nothing is on a checklist" do
      # A posted form is a pending row in every sense that matters: it's visible
      # and it's waiting on them, so saying so isn't an unbacked claim.
      prompt = chore_prompt

      messages = turn(
        [
          { tool_calls: [{ name: :answer_prompt, arguments: { "id" => prompt.id, "answers" => { "Who did it?" => "Eve" } } }] },
          { text: "That's set to log - send it when it looks right." },
        ],
        text: "eve did puppy up",
      )

      expect(messages.first.body).to eq("That's set to log - send it when it looks right.")
      expect(form_message(messages)).to be_present
    end
  end
end
