require "rails_helper"
require Rails.root.join("lib/middleware/catch_malformed_request_middleware").to_s

RSpec.describe CatchMalformedRequestMiddleware do
  let(:app) { ->(_env) { [200, { "Content-Type" => "text/plain" }, ["ok"]] } }
  let(:middleware) { described_class.new(app) }

  def env_for(method)
    Rack::MockRequest.env_for("/", method: method).merge("REQUEST_METHOD" => method)
  end

  it "passes a normal request through" do
    expect(middleware.call(env_for("GET"))).to eq([200, { "Content-Type" => "text/plain" }, ["ok"]])
  end

  it "refuses the HTTP/2 cleartext preface without calling the app" do
    expect(app).not_to receive(:call)
    status, _headers, body = middleware.call(env_for("PRI"))

    expect(status).to eq(405)
    expect(body).to eq(["Not a valid HTTP method"])
  end

  it "does not let an unknown method reach Rails' own method check" do
    expect { middleware.call(env_for("PRI")) }.not_to raise_error
  end

  it "refuses a request whose Accept header is not a MIME type" do
    raising_app = ->(_env) { raise ActionDispatch::Http::MimeNegotiation::InvalidType }
    status, _headers, body = described_class.new(raising_app).call(env_for("GET"))

    expect(status).to eq(405)
    expect(body).to eq(["Not a valid MIME type"])
  end
end
