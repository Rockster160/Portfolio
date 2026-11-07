require "rails_helper"

# A build's branch is `byte/<id>-<these words>`, so they have to read as a
# name, however the request was worded.
RSpec.describe FeatureBuilder::BranchName do
  let(:request) {
    "Let's figure out a way to make the PWAs more dynamic. First off, the manifests " \
      "need to be generated for each Buddy."
  }
  let(:build) {
    FeatureBuild.create!(user: User.me, title: FeatureBuild.title_for(request), request: request)
  }

  def answering(text, ok: true)
    allow(Buddy::GPT::Client).to receive(:new).and_return(
      instance_double(Buddy::GPT::Client, stream: { ok: ok, text: text, usage: {} }),
    )
  end

  it "uses the model's name for the request" do
    answering("dynamic-pwas")

    expect(described_class.for(build)).to eq("dynamic-pwas")
  end

  it "turns a loosely shaped answer into a branch segment" do
    answering("`Dynamic PWAs`\n\nThat names the change.")

    expect(described_class.for(build)).to eq("dynamic-pwas")
  end

  it "keeps no more than five words of a long answer" do
    answering("make every buddy install manifest dynamic now")

    expect(described_class.for(build)).to eq("make-every-buddy-install-manifest")
  end

  # The branch still gets cut when the model can't be reached, so a failed call
  # falls back to the request's own words, minus the ones that only frame it.
  it "names it from the request's own words when the model fails", :aggregate_failures do
    answering("", ok: false)
    expect(described_class.for(build)).to eq("pwas-more-dynamic-first")

    allow(Buddy::GPT::Client).to receive(:new).and_raise(StandardError, "down")
    expect(described_class.for(build)).to eq("pwas-more-dynamic-first")
  end

  it "has a name even when the request is all framing" do
    expect(described_class.from_words("Can we please add a new feature?")).to eq("feature")
  end
end
