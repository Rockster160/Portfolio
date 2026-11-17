require "rails_helper"

RSpec.describe FeatureBuilder::Title do
  let(:request) {
    "Again, I'd like the Byte responses to my feature builders to have a better title. " \
      "Instead of the whole prompt, let's summarize it."
  }

  def answering(text, ok: true)
    allow(Buddy::GPT::Client).to receive(:new).and_return(
      instance_double(Buddy::GPT::Client, stream: { ok: ok, text: text, usage: {} }),
    )
  end

  it "uses the model's title for the request" do
    answering("Short titles for builds")

    expect(described_class.for(request, user: User.me)).to eq("Short titles for builds")
  end

  it "keeps the first line and drops quotes and a closing period" do
    answering("\"Short titles for builds.\"\n\nThat names it.")

    expect(described_class.for(request, user: User.me)).to eq("Short titles for builds")
  end

  it "gives nothing when the model fails or says nothing" do
    answering("", ok: false)
    expect(described_class.for(request, user: User.me)).to be_nil

    answering("   ")
    expect(described_class.for(request, user: User.me)).to be_nil
  end

  it "gives nothing when the call raises" do
    allow(Buddy::GPT::Client).to receive(:new).and_raise(StandardError, "down")

    expect(described_class.for(request, user: User.me)).to be_nil
  end
end
