require "rails_helper"

RSpec.describe FeatureBuilder::Repos do
  let(:user) { User.me }

  def answering(text, ok: true)
    allow_any_instance_of(Buddy::GPT::Client).to receive(:stream).and_return({ ok: ok, text: text })
    allow(BuddyUsage).to receive(:record!)
  end

  it "takes the repo the model names, by its name or owner/name" do
    answering("hass-config")
    expect(described_class.for("dim the porch light at 10", user: user)).to eq("Rockster160/hass-config")

    answering("`Rockster160/slime-civ`")
    expect(described_class.for("slimes should hibernate", user: user)).to eq("Rockster160/slime-civ")
  end

  it "builds in Portfolio when the model names nothing it knows, or fails" do
    answering("broker")
    expect(described_class.for("fix the broker export", user: user)).to eq(described_class::PORTFOLIO)

    answering(nil, ok: false)
    expect(described_class.for("dark mode", user: user)).to eq(described_class::PORTFOLIO)
  end

  it "shows the model every repo it can pick" do
    expect(described_class.prompt).to include("- Portfolio: ", "- hass-config: ", "- ParkourUtah: ")
  end
end
