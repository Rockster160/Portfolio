require "rails_helper"

RSpec.describe Buddy::Moods do
  describe ".reading" do
    it "keeps only the settings given, each within 0..1" do
      expect(described_class.reading(warmth: 1.5, strain: "0.2", play: nil, groups: ["x"])).to eq(
        "warmth" => 1.0, "strain" => 0.2,
      )
    end

    it "is nil without an axis" do
      expect(described_class.reading(reach: 0.2)).to be_nil
      expect(described_class.reading(nil)).to be_nil
    end
  end

  describe ".face" do
    let(:asleep) { { "warmth" => 0.55, "play" => 0.05, "weight" => 0.2, "strain" => 0.0 } }

    it "lands on a drawn state as well as a declared mood" do
      expect(described_class.face(:tiko, asleep.merge("reach" => 0.05), seed: "a")).to eq(:sleeping)
    end

    it "lets a wider reach draw from more faces, and keeps one face per seed" do
      wide = 30.times.map { |i| described_class.face(:byte, asleep.merge("reach" => 0.3), seed: i) }
      expect(wide.uniq.size).to be > 1
      wide_again = 30.times.map { |i| described_class.face(:byte, asleep.merge("reach" => 0.3), seed: i) }
      expect(wide_again).to eq(wide)
    end

    it "counts only the axes given" do
      faces = Buddy::Companion.all.keys.map { |theme| described_class.face(theme, { "strain" => 1.0 }, seed: "a") }
      expect(faces).to all(be_present)
    end

    it "never answers with a gesture or the thinking face" do
      faces = Buddy::Companion.all.keys.flat_map { |theme|
        20.times.map { |i| described_class.face(theme, { "warmth" => 0.85, "play" => 0.5, "weight" => 0.2, "strain" => 0.05, "reach" => 0.4 }, seed: i) }
      }
      expect(faces).not_to include(:wave, :thinking)
    end
  end

  it "answers for every pet at once" do
    faces = described_class.faces({ "warmth" => 0.7, "play" => 0.5, "weight" => 0.35, "strain" => 0.05, "reach" => 0.1 }, seed: "k")

    expect(faces.keys).to match_array(Buddy::Companion.all.keys.map(&:to_s))
    expect(faces["tiko"]).to eq("nerd")
  end
end
