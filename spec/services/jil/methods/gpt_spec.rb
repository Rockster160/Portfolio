require "rails_helper"

# rubocop:disable Style/RedundantHeredocDelimiterQuotes
RSpec.describe Jil::Methods::GPT do
  let(:user) { User.me }

  before do
    user.secrets.create!(name: "OpenAI", value: "sk-test")
    user.gpt_presets.create!(name: "Calories", instructions: "Estimate calories as JSON.")
  end

  def run(code)
    Jil::Executor.call(user, code)
  end

  it "asks through a connection paid for by the named secret" do
    allow(GPTRequest).to receive(:call).with("sk-test", "Hello?", instructions: nil, json: false).and_return("Hi!")

    exe = run(<<~'JIL')
      gpt = GPT.connection("openai")::GPT
      a = gpt.ask("Hello?")::String
    JIL

    expect(exe.ctx.dig(:vars, :a, :value)).to eq("Hi!")
  end

  it "keeps the key itself out of the run" do
    allow(GPTRequest).to receive(:call).and_return("Hi!")

    exe = run(<<~'JIL')
      gpt = GPT.connection("OpenAI")::GPT
      a = gpt.ask("Hello?")::String
      p = Global.print("#{gpt}")::String
    JIL

    expect(exe.ctx.to_s).not_to include("sk-test")
  end

  it "opens with a saved preset, found regardless of case" do
    allow(GPTRequest).to receive(:call).with(
      "sk-test",
      "Food: Betos Burrito",
      instructions: "Estimate calories as JSON.",
      json:         true,
    ).and_return({ "calories" => 850, "explanation" => "Full burrito" })

    exe = run(<<~'JIL')
      gpt = GPT.connection("OpenAI")::GPT
      est = gpt.presetJson("calories", "Food: Betos Burrito")::Hash
      cals = est.get("calories")::Numeric
    JIL

    expect(exe.ctx.dig(:vars, :cals, :value)).to eq(850)
  end

  it "fails the run, by name, on a preset that doesn't exist" do
    exe = run(<<~'JIL')
      gpt = GPT.connection("OpenAI")::GPT
      a = gpt.preset("Nope", "x")::String
    JIL

    expect(exe.ctx[:error]).to include("No GPT preset named \"Nope\"")
  end

  it "fails the run, by name, on a secret that doesn't exist" do
    exe = run(<<~'JIL')
      gpt = GPT.connection("Anthropic")::GPT
      a = gpt.ask("Hello?")::String
    JIL

    expect(exe.ctx[:error]).to include("No secret named \"Anthropic\"")
  end
end
# rubocop:enable Style/RedundantHeredocDelimiterQuotes
