require "rails_helper"

# Only the ACCOUNT being unusable sleeps the house. Everything else is one turn
# going wrong, and sleeping every companion over a 502 would be worse than the
# 502 was.
RSpec.describe Buddy::GPT::Client, ".kind_of" do
  def raised(status, body=nil)
    Class.new(StandardError) {
      attr_accessor :response
    }.new("boom").tap { |e| e.response = { status: status, body: body }.compact }
  end

  def kind(exception)
    described_class.new.send(:kind_of, exception)
  end

  # A spent balance is a 429 that carries `insufficient_quota`.
  it "sleeps on a rejected key, payment required, or a spent balance" do
    quota = { "error" => { "type" => "insufficient_quota", "message" => "You have no credits remaining." } }

    expect(kind(raised(401))).to eq(:outage)
    expect(kind(raised(403))).to eq(:outage)
    expect(kind(raised(402))).to eq(:outage)
    expect(kind(raised(429, quota))).to eq(:outage)
  end

  # The account working and being asked too fast, a server error, a bad
  # request, and a timeout that never reached the provider at all.
  it "does NOT sleep on a rate limit, a server error, a bad request or a timeout" do
    limited = { "error" => { "type" => "rate_limit_exceeded", "message" => "Rate limit reached" } }

    expect(kind(raised(429, limited))).to be_nil
    expect(kind(raised(500))).to be_nil
    expect(kind(raised(400))).to be_nil
    expect(kind(StandardError.new("execution expired"))).to be_nil
  end
end
