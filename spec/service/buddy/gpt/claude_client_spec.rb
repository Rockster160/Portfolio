require "rails_helper"

RSpec.describe Buddy::GPT::ClaudeClient do
  let(:url)    { "http://mini.test" }
  let(:client) { described_class.new(url: url) }
  let(:sent)   { [] }
  let(:cache)  { ActiveSupport::Cache::MemoryStore.new }
  let(:instructions) {
    ["You are Byte.", "## Rules\n\nBe kind.", "## Right now\n\nTuesday 9pm"].join("\n\n---\n\n")
  }
  let(:tools) {
    [{ type: :function, name: :set_timer, description: "Starts a timer.", parameters: {} }]
  }

  # Byte's answers, in order, one per request that isn't an open or a close.
  def mini(*answers)
    queue = answers.dup
    stub_request(:post, "#{url}/byte/turn").to_return { |request|
      body = JSON.parse(request.body, symbolize_names: true)
      sent << body
      answer = (
        case body[:action]
        when "open"  then { ok: true, id: "s#{sent.count { |b| b[:action] == "open" }}" }
        when "close" then { ok: true, closed: true }
        else queue.shift
        end
      )
      { status: 200, body: JSON.generate(answer) }
    }
  end

  def say(content, input: nil)
    input ||= [{ role: :user, content: content }]
    client.stream(instructions: instructions, input: input, tools: tools)
  end

  def calls_answer(name)
    {
      ok:    true,
      kind:  :calls,
      calls: [{ id: "t1", name: name, arguments: { minutes: 5 } }],
      text:  "",
      usage: [{ input_tokens: 2, cache_read_input_tokens: 900 }],
    }
  end

  def reply_answer(text, events: [])
    { ok: true, kind: :reply, text: text, usage: [{ input_tokens: 2 }], events: events }
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  it "opens on the prompt that stays put and leads the first message with the rest" do
    mini(reply_answer("Hi!"))
    say("hey")

    opened = sent.first
    expect(opened).to include(action: "open", model: "claude-haiku-5-5", effort: "low")
    expect(opened[:system]).to include("Be kind.").and include("mcp__buddy__NAME")
    expect(opened[:system]).not_to include("Tuesday 9pm")
    expect(opened[:tools].first[:name]).to eq("set_timer")
    expect(sent.second).to include(action: "say", message: "## Right now\n\nTuesday 9pm\n\nhey")
  end

  it "ends a round on its calls and answers them on the next, notes riding along" do
    mini(calls_answer(:set_timer), reply_answer("Timer's on."))
    events = []
    input  = [{ role: :user, content: "5 minute timer" }]
    first  = client.stream(instructions: instructions, input: input, tools: tools) { |event|
      events << event
    }

    call = { name: :set_timer, call_id: "t1", arguments: { "minutes" => 5 } }
    expect(first).to include(ok: true, model: "claude-haiku-5-5", tool_calls: [call])
    expect(events).to eq([call.merge(type: :tool_call)])
    expect(first[:usage]).to include(input_tokens: 902, cached_input_tokens: 900)

    input += [
      { type: :function_call, call_id: "t1", name: "set_timer", arguments: "{}" },
      { type: :function_call_output, call_id: "t1", output: "landed" },
      { role: :developer, content: "Say it landed." },
    ]
    second = say(nil, input: input)

    expect(second).to include(ok: true, text: "Timer's on.", tool_calls: [])
    expect(sent.last).to include(action: "answer", id: "s1")
    expect(sent.last[:results]).to eq([
      { id: "t1", output: "landed\n\n[app] Say it landed.", images: [] },
    ])
  end

  it "sends a picture as an image block for the Mini to fetch" do
    mini(reply_answer("Cute dog."))
    say([
      { type: :input_text, text: "look" },
      { type: :input_image, image_url: "https://s3.test/dog.jpg" },
    ])

    expect(sent.second[:message]).to include(
      { type: "text", text: "look" },
      { type: "image", source: { type: "url", url: "https://s3.test/dog.jpg" } },
    )
  end

  it "starts a new session when the input isn't the one it was carrying on" do
    mini(reply_answer("One."), reply_answer("Two."))
    say("first try")
    say("again")

    expect(sent.pluck(:action)).to eq(%w[open say close open say])
  end

  it "calls a Mini it can't reach its own failure, and leaves it alone for a bit" do
    stub_request(:post, "#{url}/byte/turn").to_raise(Errno::ECONNREFUSED)

    expect(say("hi")).to include(ok: false, error_kind: :mini)
    expect(described_class.available?).to be(false)
  end

  it "keeps a quiet turn the model's own, not the Mini's" do
    mini(reply_answer(""))

    expect(say("hi")).to include(ok: false, error: Buddy::GPT::Client::EMPTY_TURN, error_kind: nil)
    expect(described_class.available?).to be(true)
  end

  it "hands the Mini the mood reading to start, and collects it by the session" do
    mood = { system: "Read the mood.", transcript: "Them: hi", note: nil, max_chars: 320 }
    mini(reply_answer("Hi!"), { ok: true, text: '{"warmth":0.7}', usage: [{ input_tokens: 9 }] })
    client.mood = mood
    say("hi")

    expect(sent.first[:mood]).to eq(mood)
    expect(client.mood_session).to eq("s1")
    expect(client.mood_reading("s1")).to include(ok: true, text: '{"warmth":0.7}')
    expect(sent.last).to eq({ action: "mood", id: "s1" })
  end

  it "steps aside until the week resets once the plan is nearly used" do
    resets = 2.days.from_now.to_i
    week   = { utilization: 0.96, resetsAt: resets, status: "allowed" }
    limit  = { type: "rate_limit_event", rate_limit_info: { unifiedWindows: { seven_day: week } } }
    mini(reply_answer("Hi!", events: [limit]))
    say("hi")

    expect(described_class.available?).to be(false)
    travel_to(Time.zone.at(resets) + 1.minute) { expect(described_class.available?).to be(true) }
  end
end
