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

  # A term naming no key is dropped rather than turning the whole string into
  # the scope; it still names the scope it meant.
  it "reads the listener grammar out of the string" do
    [
      ['{"trigger":"garage:direction:open"}', [["garage", { "direction" => "open" }]]],
      ['{"trigger":"garage direction:open"}', [["garage", { "direction" => "open" }]]],
      ['{"trigger":"battery phone:value:70"}', [["battery", { "phone" => { "value" => "70" } }]]],
      ['{"trigger":"watch-action a:b:c d:e"}', [["watch-action", { "a" => { "b" => "c" }, "d" => "e" }]]],
      ['{"trigger":"note body:\"hello there\""}', [["note", { "body" => "hello there" }]]],
      ['{"trigger":"link url:https\\\\://example.com"}', [["link", { "url" => "https://example.com" }]]],
      ['{"trigger":"garage open"}', [["garage", {}]]],
      ['{"trigger":"watch-action"}', [["watch-action", {}]]],
      ['{"trigger":"garage:direction:open","data":{"direction":"close"}}', [["garage", { "direction" => "close" }]]],
      ['{"trigger":"garage:direction:open","source":"watch"}', [["garage", { "source" => "watch", "direction" => "open" }]]],
    ].each do |body, expected|
      expect(triggered(body)).to eq(expected), body
    end
  end

  it "reads a JSON body sent as a text/plain File" do
    seen = []
    allow(Jil).to receive(:trigger) { |_u, scope, data, **| seen << [scope, data] }
    post("/jil/trigger", params: '{"trigger":"tv-mute","source":"watch"}', headers: {
      "HTTP_AUTHORIZATION" => "Bearer #{key.key}",
      "CONTENT_TYPE"       => "text/plain",
    })

    expect(seen).to eq([["tv-mute", { "source" => "watch" }]])
  end

  it "takes the trigger from a GET query, with no body" do
    seen = []
    allow(Jil).to receive(:trigger) { |_u, scope, data, **| seen << [scope, data] }
    get("/jil/trigger", params: { trigger: "garage:direction:open" }, headers: {
      "HTTP_AUTHORIZATION" => "Bearer #{key.key}",
    })

    expect(response).to have_http_status(:ok)
    expect(seen).to eq([["garage", { "direction" => "open" }]])
  end

  it "takes a whole JSON payload from a GET's json param" do
    seen = []
    allow(Jil).to receive(:trigger) { |_u, scope, data, **| seen << [scope, data] }
    get(
      "/jil/trigger",
      params:  { json: '{"trigger":"tv-mute","source":{"device":"watch"}}' },
      headers: { "HTTP_AUTHORIZATION" => "Bearer #{key.key}" },
    )

    expect(seen).to eq([["tv-mute", { "source" => { "device" => "watch" } }]])
  end

  it "refuses a GET carrying no credentials" do
    allow(Jil).to receive(:trigger)
    get("/jil/trigger", params: { trigger: "tv-mute" })

    expect(response).to have_http_status(:no_content)
    expect(Jil).not_to have_received(:trigger)
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
