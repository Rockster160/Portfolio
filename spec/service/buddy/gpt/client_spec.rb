require "rails_helper"

# The ONLY Buddy spec that exercises HTTP, and it does so against a WebMock stub
# rather than OpenAI. Everything above the client is tested through
# FakeBuddyClient (see spec/support/buddy_gpt_fake_client.rb), so this file only
# has to prove we speak the wire protocol correctly.
RSpec.describe Buddy::GPT::Client do
  let(:endpoint) { "https://api.openai.com/v1/responses" }

  # Server-sent events as the Responses API frames them: one `data:` line per
  # event, blank-line separated, terminated by [DONE].
  def sse(*events)
    events.map { |e| "data: #{JSON.generate(e)}\n\n" }.join + "data: [DONE]\n\n"
  end

  def stub_sse(body, status: 200)
    stub_request(:post, endpoint).to_return(
      status:  status,
      body:    body,
      headers: { "Content-Type" => "text/event-stream" },
    )
  end

  def text_delta(text, item_id: nil, content_index: 0)
    { type: "response.output_text.delta", delta: text, item_id: item_id, content_index: content_index }.compact
  end

  def function_call(name, arguments, call_id: "call_1", id: "fc_1")
    {
      type: "response.output_item.done",
      item: { type: "function_call", id: id, call_id: call_id, name: name, arguments: arguments },
    }
  end

  def usage_payload(input: 1_000, cached: 800, output: 100, reasoning: 20)
    {
      input_tokens:          input,
      input_tokens_details:  { cached_tokens: cached, cache_write_tokens: 0 },
      output_tokens:         output,
      output_tokens_details: { reasoning_tokens: reasoning },
      total_tokens:          input + output,
    }
  end

  def completed(id: "resp_1", usage: usage_payload)
    { type: "response.completed", response: { id: id, usage: usage }.compact }
  end

  def run(&block)
    described_class.new.stream(instructions: "be warm", input: [{ role: :user, content: "hi" }], &block)
  end

  describe "text streaming" do
    # Prod message 1106 landed as "...keep an eye on that.Yep, I'm watching for
    # the next deploy to finish." - one API call, no newline anywhere in the
    # body. Two separate message items had their deltas appended into the same
    # buffer with nothing between them, fusing two replies mid-sentence.
    it "keeps separate output items apart instead of fusing them mid-sentence" do
      stub_sse(sse(
        text_delta("You got it. ",   item_id: "msg_1"),
        text_delta("I'll watch it.", item_id: "msg_1"),
        text_delta("Yep, watching.", item_id: "msg_2"),
        completed,
      ))

      expect(run[:text]).to eq("You got it. I'll watch it.\n\nYep, watching.")
    end

    # Prod message 1313 read "Here's what you've got.\n\nHere's what you've got."
    # - one call, two message items, the same sentence in both. Keeping the seam
    # is right; keeping the repeat is just making them read it twice.
    it "drops a part that only repeats one it already kept" do
      stub_sse(sse(
        text_delta("Here's what you've got.", item_id: "msg_1"),
        text_delta("Here's what you've got.", item_id: "msg_2"),
        completed,
      ))

      expect(run[:text]).to eq("Here's what you've got.")
    end

    it "separates two content parts within a single item" do
      stub_sse(sse(
        text_delta("First.",  item_id: "msg_1", content_index: 0),
        text_delta("Second.", item_id: "msg_1", content_index: 1),
        completed,
      ))

      expect(run[:text]).to eq("First.\n\nSecond.")
    end

    it "accumulates deltas and yields each one" do
      stub_sse(sse(text_delta("Hey"), text_delta(" there"), completed))

      seen = []
      result = run { |e| seen << e }

      expect(result[:ok]).to be(true)
      expect(result[:text]).to eq("Hey there")
      expect(result[:response_id]).to eq("resp_1")
      expect(seen).to eq([
        { type: :text_delta, text: "Hey" },
        { type: :text_delta, text: " there" },
      ])
    end

    it "handles multi-byte characters split across the stream" do
      stub_sse(sse(text_delta("caf"), text_delta("é ☕"), completed))

      expect(run[:text]).to eq("café ☕")
    end
  end

  describe "tool calls" do
    it "parses arguments and yields the call" do
      stub_sse(sse(function_call("complete_chore", '{"chore":"dishes","count":2}'), completed))

      seen = []
      result = run { |e| seen << e }

      expect(result[:tool_calls]).to eq([
        { name: :complete_chore, call_id: "call_1", arguments: { "chore" => "dishes", "count" => 2 } },
      ])
      expect(seen.first[:type]).to eq(:tool_call)
    end

    it "treats empty arguments as an empty hash rather than a failure" do
      stub_sse(sse(function_call("get_context", ""), completed))

      expect(run[:tool_calls].first[:arguments]).to eq({})
    end

    it "drops a call with unparseable arguments instead of raising" do
      stub_sse(sse(text_delta("Sure."), function_call("log_event", "{not json"), completed))

      result = run

      expect(result[:ok]).to be(true)
      expect(result[:text]).to eq("Sure.")
      expect(result[:tool_calls]).to be_empty
    end

    it "collects several calls in stream order" do
      stub_sse(sse(
                 function_call("create_chore", '{"name":"Mow"}', call_id: "c1", id: "f1"),
        function_call("complete_chore", '{"chore":"Mow"}', call_id: "c2", id: "f2"),
        completed,
      ))

      expect(run[:tool_calls].pluck(:name)).to eq([:create_chore, :complete_chore])
    end

    it "ignores non-function output items" do
      stub_sse(sse(
                 { type: "response.output_item.done", item: { type: "message", content: [] } },
        text_delta("hi"),
        completed,
      ))

      expect(run[:tool_calls]).to be_empty
    end
  end

  describe "usage reporting" do
    it "flattens the nested usage payload off response.completed" do
      stub_sse(sse(text_delta("hi"), completed))

      result = run

      expect(result[:usage]).to eq(
        input_tokens:        1_000,
        cached_input_tokens: 800,
        output_tokens:       100,
        reasoning_tokens:    20,
        total_tokens:        1_100,
      )
      expect(result[:model]).to eq("gpt-5.4-mini")
    end

    it "defaults the nested detail objects to zero when absent" do
      stub_sse(sse(text_delta("hi"), completed(usage: {
        input_tokens: 50, output_tokens: 7, total_tokens: 57
      })))

      expect(run[:usage]).to include(cached_input_tokens: 0, reasoning_tokens: 0)
    end

    it "captures usage from a failed response, which still billed" do
      stub_sse(sse({
        type:     "response.failed",
        response: { id: "resp_x", error: { message: "too long" }, usage: usage_payload(input: 400) },
      }))

      result = run

      expect(result[:ok]).to be(false)
      expect(result[:usage][:input_tokens]).to eq(400)
    end

    it "reports no usage when the request was rejected before running" do
      stub_sse(JSON.generate({ error: { message: "invalid schema" } }), status: 400)

      expect(run[:usage]).to be_nil
    end
  end

  describe "the wall-clock deadline" do
    # Faraday's request_timeout is per-READ, so a stream that keeps trickling
    # never trips it. One prod turn ran 3m45s that way and blocked every message
    # behind it on the conversation lock.
    def stream_with_deadline(deadline)
      described_class.new.stream(
        instructions: "x", input: [{ role: :user, content: "hi" }], deadline: deadline,
      )
    end

    it "keeps the prose it already streamed when the budget runs out" do
      stub_sse(sse(text_delta("Partial thought"), text_delta(" continues"), completed))

      result = stream_with_deadline(1.hour.ago)

      expect(result[:ok]).to be(true)
      expect(result[:text]).to include("Partial")
      expect(result[:error]).to be_nil
    end

    it "keeps a completed tool call, since only whole items ever arrive" do
      stub_sse(sse(function_call("log_event", '{"name":"Coffee"}'), completed))

      result = stream_with_deadline(1.hour.ago)

      expect(result[:tool_calls].first).to include(name: :log_event)
    end

    it "reports failure when the budget ran out before anything usable arrived" do
      stub_sse(sse(completed))

      result = stream_with_deadline(1.hour.ago)

      expect(result[:ok]).to be(false)
      expect(result[:error]).to eq("timed out")
    end

    it "does not interfere with a stream that finishes in time" do
      stub_sse(sse(text_delta("All good"), completed))

      result = stream_with_deadline(1.hour.from_now)

      expect(result[:ok]).to be(true)
      expect(result[:text]).to eq("All good")
      expect(result[:usage]).to be_present
    end
  end

  describe "failure modes" do
    it "reports a turn that produced neither text nor tool calls as not ok" do
      stub_sse(sse(completed))

      result = run

      expect(result[:ok]).to be(false)
      expect(result[:error]).to match(/no text and no tool calls/)
    end

    it "surfaces an explicit stream error" do
      stub_sse(sse(text_delta("partial"), { type: "error", message: "context length exceeded" }))

      result = run

      expect(result[:ok]).to be(false)
      expect(result[:error]).to eq("context length exceeded")
      expect(result[:text]).to eq("partial")
    end

    it "surfaces a response.failed event" do
      stub_sse(sse({
        type:     "response.failed",
        response: { id: "resp_x", error: { message: "server had a moment" } },
      }))

      expect(run[:error]).to eq("server had a moment")
    end

    it "returns an error instead of raising when the API rejects the request" do
      stub_sse(JSON.generate({ error: { message: "invalid schema" } }), status: 400)

      result = run

      expect(result[:ok]).to be(false)
      expect(result[:error]).to be_present
    end

    it "does not carry an error from one turn into the next on a reused client" do
      client = described_class.new
      stub_sse(sse({ type: "error", message: "transient" }))
      first = client.stream(instructions: "x", input: [])
      expect(first[:ok]).to be(false)

      stub_sse(sse(text_delta("fine now"), completed))
      second = client.stream(instructions: "x", input: [])

      expect(second[:ok]).to be(true)
      expect(second[:error]).to be_nil
    end
  end

  describe "the request body" do
    it "sends the model, instructions, input, and flat function tools" do
      stub_sse(sse(text_delta("ok"), completed))
      tools = [Buddy::GPT::ContextTool.schema]

      described_class.new(model: "gpt-5.4-mini").stream(
        instructions: "be warm", input: [{ role: :user, content: "hi" }], tools: tools,
      )

      expect(WebMock).to(have_requested(:post, endpoint).with { |req|
        body = JSON.parse(req.body)
        expect(body["model"]).to eq("gpt-5.4-mini")
        expect(body["instructions"]).to eq("be warm")
        expect(body["stream"]).to be(true)
        expect(body["store"]).to be(false)
        # Flat shape: name at the top level, NOT nested under "function".
        expect(body["tools"].first["name"]).to eq("get_context")
        expect(body["tools"].first).not_to have_key("function")
        true
      })
    end

    # Buddy shipped with no reasoning parameter at all, which measured as zero
    # reasoning tokens over 53 prod calls - the model was never thinking before
    # it answered. `low` beat both no-parameter and `medium` on tool-call
    # reliability AND latency; see the constant for the numbers.
    it "asks for low reasoning effort by default" do
      stub_sse(sse(text_delta("ok"), completed))

      run

      expect(WebMock).to(have_requested(:post, endpoint).with { |req|
        JSON.parse(req.body).dig("reasoning", "effort") == "low"
      })
    end

    it "omits reasoning when a caller explicitly opts out (compaction)" do
      stub_sse(sse(text_delta("ok"), completed))

      described_class.new(reasoning_effort: nil).stream(instructions: "x", input: [])

      expect(WebMock).to(have_requested(:post, endpoint).with { |req|
        !JSON.parse(req.body).key?("reasoning")
      })
    end

    it "omits tools entirely when none are given" do
      stub_sse(sse(text_delta("ok"), completed))

      run

      expect(WebMock).to(have_requested(:post, endpoint).with { |req|
        !JSON.parse(req.body).key?("tools")
      })
    end

    it "defaults the model from the environment" do
      expect(described_class.new.model).to eq("gpt-5.4-mini")
    end
  end
end
