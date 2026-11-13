require "rails_helper"

RSpec.describe Buddy::Faces, ".named" do
  it "answers working with Byte's own laptop drawing" do
    expect(Buddy::Faces.named(:byte, :working)).to eq(:working)
  end

  it "answers working with the laptop on the pets whose focused face is one" do
    [:tiko, :cobalt, :flux, :bloom].each do |theme|
      expect(Buddy::Faces.named(theme, :working)).to eq(:focused), theme.to_s
    end
  end

  it "answers working for every pet" do
    Buddy::Companion.all.each_key do |theme|
      expect(Buddy::Faces.named(theme, :working)).to be_present, theme.to_s
    end
  end

  it "never answers a mood with working" do
    focused = { warmth: 0.50, play: 0.13, weight: 0.62, strain: 0.15 }

    expect(Buddy::Moods.face(:byte, focused, seed: "x")).not_to eq(:working)
  end
end
