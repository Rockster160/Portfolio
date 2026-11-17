require "rails_helper"
require Rails.root.join("lib/deploy_banner").to_s

RSpec.describe DeployBanner do
  let(:time) { Time.new(2026, 11, 17, 21, 37, 0, "-07:00") }

  def visible(line) = line.gsub(/\e\[[\d;]*m/, "")

  describe ".line" do
    it "centers the time and subject in a rule exactly 74 wide" do
      shown = visible(described_class.line(time: time, subject: "Better naming"))

      expect(shown.length).to eq(74)
      expect(shown).to match(/\A(━+) Nov 17 9:37pm · Better naming (━+)\z/)
      left, right = shown.scan(/━+/).map(&:length)
      expect((left - right).abs).to be <= 1
    end

    it "shortens a long subject on a word and keeps the rule on both sides" do
      shown = visible(described_class.line(time: time, subject: "#91 Boards can be named by the pet on them, in Jil yells and sounds and in timers"))

      expect(shown.length).to eq(74)
      expect(shown).to include("· #91 Boards can be named by the pet on them, in Jil…")
      expect(shown).to match(/\A━{2,} .* ━{2,}\z/)
    end
  end

  describe ".subject" do
    it "names a PR merge by its number and title" do
      message = "Merge pull request #92 from Rockster160/byte/37-x\n\nSet what a button does by telling Buddy\n"

      expect(described_class.subject(message)).to eq("#92 Set what a button does by telling Buddy")
    end

    it "names a branch merge by the last real commit under it" do
      message = "Merge branch 'master' of github.com:Rockster160/Portfolio"

      expect(described_class.subject(message, last_change: "Agenda usability")).to eq("Agenda usability")
    end

    it "names a direct push by its first line" do
      expect(described_class.subject("Better naming\n\nlonger body")).to eq("Better naming")
    end
  end
end
