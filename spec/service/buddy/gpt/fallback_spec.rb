require "rails_helper"

RSpec.describe Buddy::GPT::Fallback do
  let(:request) { { instructions: "Be Byte.", input: [{ role: :user, content: "hi" }], tools: [] } }
  let(:backup)  { FakeBuddyClient.new([{ text: "Hi from GPT." }, { text: "Still GPT." }]) }

  def primary(*results)
    instance_double(Buddy::GPT::ClaudeClient, model: "claude-haiku-5-5", finish: nil).tap { |claude|
      allow(claude).to receive(:stream).and_return(*results)
    }
  end

  it "hands a turn the Mini couldn't take to GPT, and keeps it there" do
    claude   = primary({ ok: false, error: "Errno::ECONNREFUSED", error_kind: :mini })
    fallback = described_class.new(claude, backup)

    expect(fallback.stream(**request)).to include(ok: true, text: "Hi from GPT.")
    expect(backup.calls.first.input).to eq(request[:input])
    expect(fallback.stream(**request)).to include(text: "Still GPT.")
    expect(claude).to have_received(:stream).once
    expect(fallback.model).to eq(FakeBuddyClient::DEFAULT_MODEL)
  end

  it "keeps Claude's own answers, a quiet one included" do
    quiet    = { ok: false, error: Buddy::GPT::Client::EMPTY_TURN, error_kind: nil }
    fallback = described_class.new(primary(quiet), backup)

    expect(fallback.stream(**request)).to eq(quiet)
    expect(backup.calls).to be_empty
  end

  it "stays on GPT outside production" do
    expect(described_class.client).to be_a(Buddy::GPT::Client)
  end
end
