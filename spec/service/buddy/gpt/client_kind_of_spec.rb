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

  it "sleeps on a rejected key" do
    expect(kind(raised(401))).to eq(:outage)
    expect(kind(raised(403))).to eq(:outage)
  end

  it "sleeps on payment required" do
    expect(kind(raised(402))).to eq(:outage)
  end

  # Prod 4185: this exact message went into the thread as Buddy's reply, billing
  # link and all.
  it "sleeps on a spent balance" do
    body = {
      "error" => {
        "type"    => "insufficient_quota",
        "message" => "You have no credits remaining. Add credits to continue.",
      },
    }

    expect(kind(raised(429, body))).to eq(:outage)
  end

  # The account working, and being asked too fast.
  it "does NOT sleep on a plain rate limit" do
    body = { "error" => { "type" => "rate_limit_exceeded", "message" => "Rate limit reached" } }

    expect(kind(raised(429, body))).to be_nil
  end

  it "does NOT sleep on a server error or a bad request" do
    expect(kind(raised(500))).to be_nil
    expect(kind(raised(400))).to be_nil
  end

  # A timeout raises with no response at all.
  it "does NOT sleep on something that never reached the provider" do
    expect(kind(StandardError.new("execution expired"))).to be_nil
  end
end
