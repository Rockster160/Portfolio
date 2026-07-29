require "rails_helper"

# Buddy answering/skipping the app's own Prompt surveys on the person's behalf.
RSpec.describe "Buddy prompt tools" do
  let(:user) { create(:user) }

  def make_prompt(question:, options:)
    Prompt.create!(user: user, question: question, options: options, answer_type: :single)
  end

  def run(tool_name, payload)
    tool = Buddy::Tools[tool_name]
    ctx  = Buddy::ToolContext.new(user)
    confirm = tool[:confirm].call(payload, ctx)
    tool[:execute].call(payload.merge(confirm[:resolved] || {}), Buddy::ToolContext.new(user))
  end

  before {
    allow(::Jil).to receive(:trigger)
    allow(::WebPushNotifications).to receive(:update_count)
  }

  describe Buddy::PromptAnswer do
    it "maps a plain answer onto a single text question" do
      prompt = make_prompt(question: "Dinner?", options: [{ "question" => "What sounds good?", "type" => "text" }])
      response, key = described_class.build(prompt, "tacos")
      expect(key).to eq("What sounds good?")
      expect(response).to eq("What sounds good?" => "tacos")
    end

    it "splits a choices answer into the matched labels and keeps hidden defaults" do
      prompt = make_prompt(question: "Love languages", options: [
        { "question" => "Which resonate?", "type" => "choices", "choices" => %w[Words Time Touch Service Gifts] },
        { "question" => "src", "type" => "hidden", "default" => "buddy" },
      ])
      response, key = described_class.build(prompt, "words, touch")
      expect(key).to eq("Which resonate?")
      expect(response["Which resonate?"]).to eq(%w[Words Touch])
      expect(response["src"]).to eq("buddy")
    end

    it "declines a multi-question prompt (answerable nil)" do
      prompt = make_prompt(question: "Two things", options: [
        { "question" => "A?", "type" => "text" }, { "question" => "B?", "type" => "text" }
      ])
      _response, key = described_class.build(prompt, "x")
      expect(key).to be_nil
    end
  end

  it "answer_prompt records the response and marks the prompt answered" do
    prompt = make_prompt(question: "Dinner?", options: [{ "question" => "What sounds good?", "type" => "text" }])

    run(:answer_prompt, { id: prompt.id, answer: "tacos" })

    expect(prompt.reload.response).to eq("What sounds good?" => "tacos")
    expect(user.prompts.unanswered).to be_empty
    expect(::Jil).to have_received(:trigger).with(user, :prompt, anything)
  end

  it "skip_prompt destroys the prompt and fires the skip trigger" do
    prompt = make_prompt(question: "Dinner?", options: [{ "question" => "What sounds good?", "type" => "text" }])

    run(:skip_prompt, { id: prompt.id })

    expect(Prompt.find_by(id: prompt.id)).to be_nil
    expect(::Jil).to have_received(:trigger).with(user, :prompt, anything)
  end

  it "surfaces unanswered prompts in context (read-on-demand), not the at-a-glance" do
    prompt = make_prompt(question: "Dinner?", options: [
      { "question" => "What sounds good?", "type" => "select", "choices" => %w[Tacos Pizza] },
    ])

    listed = Buddy::Context.send(:pending_prompts, user)
    expect(listed).to include(hash_including(id: prompt.id, title: "Dinner?"))
    expect(listed.first[:questions].first).to include(q: "What sounds good?", type: "select")
  end
end
