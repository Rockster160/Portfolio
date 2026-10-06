require "rails_helper"

RSpec.describe GPTRequest do
  let(:endpoint) { "https://api.openai.com/v1/chat/completions" }

  def reply(content)
    { status: 200, headers: { "Content-Type" => "application/json" }, body: {
      choices: [{ message: { role: :assistant, content: content } }],
    }.to_json }
  end

  it "pays with the key it's given and sends the instructions as the system message" do
    stub = stub_request(:post, endpoint).with { |req|
      body = JSON.parse(req.body)
      req.headers["Authorization"] == "Bearer sk-user-own" &&
        body["messages"] == [
          { "role" => "system", "content" => "Be brief." },
          { "role" => "user", "content" => "Why is the sky blue?" },
        ] &&
        !body.key?("response_format")
    }.to_return(reply("Scattering."))

    expect(described_class.call("sk-user-own", "Why is the sky blue?", instructions: "Be brief.")).to eq("Scattering.")
    expect(stub).to have_been_requested
  end

  it "asks for a JSON object and hands back a Hash" do
    stub_request(:post, endpoint).with { |req|
      JSON.parse(req.body)["response_format"] == { "type" => "json_object" }
    }.to_return(reply({ calories: 850, explanation: "Full burrito" }.to_json))

    expect(described_class.call("sk-x", "Betos Burrito", json: true)).to eq(
      "calories" => 850, "explanation" => "Full burrito",
    )
  end

  it "refuses without a key rather than falling back to the server's" do
    expect { described_class.call("", "hi") }.to raise_error(GPTRequest::Error, /No OpenAI key/)
  end

  it "says so when the reply is not the JSON object it asked for" do
    stub_request(:post, endpoint).to_return(reply("about 850"))

    expect { described_class.call("sk-x", "Betos Burrito", json: true) }.to raise_error(GPTRequest::Error, /invalid JSON/)
  end

  it "turns a rejected request into its own error" do
    stub_request(:post, endpoint).to_return(status: 401, body: { error: { message: "bad key" } }.to_json)

    expect { described_class.call("sk-x", "hi") }.to raise_error(GPTRequest::Error, /OpenAI request failed/)
  end
end
