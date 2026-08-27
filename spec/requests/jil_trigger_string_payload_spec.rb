require "rails_helper"

# A Shortcut's "Jil Trigger" action can hand over exactly one string. Reading
# the listener grammar back out of it is the only way that string carries a
# payload — see WebhooksController#parse_trigger_string.
RSpec.describe "POST /jil/trigger with a listener-shaped string", type: :request do
  let(:user) { User.me }
  let!(:key) { user.api_keys.create!(name: "Shortcuts") }

  def fire(body)
    post("/jil/trigger", params: body, headers: {
      "HTTP_AUTHORIZATION" => "Bearer #{key.key}",
      "CONTENT_TYPE"       => "application/json",
    })
  end

  # What actually reached Jil, rather than what a task made of it.
  def triggered(body)
    seen = []
    allow(Jil).to receive(:trigger) { |_u, scope, data, **| seen << [scope, data] }
    fire(body)
    seen
  end

  it "splits the scope off the front and nests the rest" do
    expect(triggered('{"trigger":"garage:direction:open"}')).to eq(
      [["garage", { "direction" => "open" }]],
    )
  end

  it "takes the terms whitespace-separated too, the way a listener is written" do
    expect(triggered('{"trigger":"garage direction:open"}')).to eq(
      [["garage", { "direction" => "open" }]],
    )
  end

  it "walks as deep as the term goes" do
    expect(triggered('{"trigger":"battery phone:value:70"}')).to eq(
      [["battery", { "phone" => { "value" => "70" } }]],
    )
  end

  it "merges several terms into one payload" do
    expect(triggered('{"trigger":"watch-action a:b:c d:e"}')).to eq(
      [["watch-action", { "a" => { "b" => "c" }, "d" => "e" }]],
    )
  end

  it "keeps a quoted value whole, and unwraps it" do
    expect(triggered('{"trigger":"note body:\"hello there\""}')).to eq(
      [["note", { "body" => "hello there" }]],
    )
  end

  it "keeps a colon that was escaped to survive the split" do
    expect(triggered('{"trigger":"link url:https\\\\://example.com"}')).to eq(
      [["link", { "url" => "https://example.com" }]],
    )
  end

  # The failure this replaces: a term naming no key had nowhere to go, so the
  # whole string became the scope and matched nothing. Dropping the term is the
  # honest version — it still names the scope it meant.
  it "drops a term that names no key rather than inventing one" do
    expect(triggered('{"trigger":"garage open"}')).to eq([["garage", {}]])
  end

  describe "what every current caller sends" do
    it "leaves a plain scope exactly as it was" do
      expect(triggered('{"trigger":"watch-action"}')).to eq([["watch-action", {}]])
    end

    it "leaves the path form alone, body and all" do
      seen = []
      allow(Jil).to receive(:trigger) { |_u, scope, data, **| seen << [scope, data] }
      post("/jil/trigger/battery", params: '{"battery":{"watch":{"value":70}}}', headers: {
        "HTTP_AUTHORIZATION" => "Bearer #{key.key}",
        "CONTENT_TYPE"       => "application/json",
      })

      expect(seen).to eq([["battery", { "battery" => { "watch" => { "value" => 70 } } }]])
    end

    it "still prefers an explicit `data` key over anything parsed" do
      expect(triggered('{"trigger":"garage:direction:open","data":{"direction":"close"}}')).to eq(
        [["garage", { "direction" => "close" }]],
      )
    end

    it "keeps sibling body keys alongside the parsed ones" do
      expect(triggered('{"trigger":"garage:direction:open","source":"watch"}')).to eq(
        [["garage", { "source" => "watch", "direction" => "open" }]],
      )
    end
  end

  it "reaches a task listening on the scope, carrying the payload" do
    user.tasks.create!(
      name:     "String Payload Listener",
      listener: "stringpayload:direction:/^(?<direction>open|close)$/",
      enabled:  true,
      code:     "d = Global.input_data()::Hash\nout = d.get(\"direction\")::String\n",
    )

    expect { fire('{"trigger":"stringpayload:direction:open"}') }.to(
      change { user.executions.count }.by(1),
    )
    expect(response).to have_http_status(:ok)

    execution = user.executions.last
    expect(execution.trigger_scope).to eq("stringpayload")
    expect(execution.input_data["direction"]).to eq("open")
    expect(execution.input_data.dig("named_captures", "direction")).to eq("open")
  end
end
