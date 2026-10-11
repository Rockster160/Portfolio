require "rails_helper"

# `dismissed_until` is read against the CHORE-DAY, not the clock, and that is
# the whole reason there is no cleanup job: a wave-off expires because the day
# moved on, so nothing has to go round clearing it. Which means the 4am cutoff
# is load-bearing here, and this is where it gets pinned down.
RSpec.describe Chore do
  let(:user) { create(:user) }
  let(:chore) { create(:chore, created_by_user: user, name: "Vacuum") }

  describe "#dismissed?" do
    it "is false with nothing stored" do
      expect(chore.dismissed?(user)).to be(false)
    end

    it "holds through the day it was made on" do
      chore.dismissed_until = ChoreDay.current(user)

      expect(chore.dismissed?(user)).to be(true)
    end

    # Inclusive on purpose: a chore waved off "for today" carries today, and
    # today is the day it isn't being asked about.
    it "is over once the chore-day has moved past it" do
      chore.dismissed_until = ChoreDay.current(user) - 1

      expect(chore.dismissed?(user)).to be(false)
    end

    # 3am is still yesterday to a chore, so a wave-off made at 11pm has to
    # survive until the 4am cutoff rather than expiring at midnight. Getting
    # this wrong puts the chore back on the board in the middle of the night.
    it "survives midnight and ends at the 4am cutoff" do
      day = Date.new(2026, 10, 10)
      chore.dismissed_until = day
      zone = ActiveSupport::TimeZone["America/Denver"]

      expect(chore.dismissed?(user, at: zone.local(2026, 10, 10, 23, 30))).to be(true)
      expect(chore.dismissed?(user, at: zone.local(2026, 10, 11, 3, 30))).to be(true)
      expect(chore.dismissed?(user, at: zone.local(2026, 10, 11, 4, 30))).to be(false)
    end
  end

  describe ".dismissed_until_for" do
    let(:today) { ChoreDay.current(user) }

    it "lands a day-skip on the chore-day itself" do
      expect(described_class.dismissed_until_for(:day, user)).to eq(today)
    end

    it "lands a week-skip seven days out" do
      expect(described_class.dismissed_until_for(:week, user)).to eq(today + 7)
    end

    # A calendar month rather than 30 days - said on the 31st, 30 days is five
    # weeks away and reads as a mistake.
    it "lands a month-skip a calendar month out" do
      expect(described_class.dismissed_until_for(:month, user)).to eq(today + 1.month)
    end

    it "takes a string as readily as a symbol, since one arrives from params" do
      expect(described_class.dismissed_until_for("week", user)).to eq(today + 7)
    end

    it "raises on a span it doesn't know rather than picking one" do
      expect { described_class.dismissed_until_for(:fortnight, user) }
        .to raise_error(ArgumentError, /fortnight/)
    end
  end

  describe ".tagged" do
    it "matches regardless of how the tag was typed" do
      home = create(:chore, created_by_user: user, name: "Vacuum", tag: "Home")
      create(:chore, created_by_user: user, name: "Feed Whisper", tag: "Pets")

      expect(described_class.tagged("home")).to eq([home])
      expect(described_class.tagged("  HOME ")).to eq([home])
    end

    it "matches nothing for a tag nobody uses, rather than everything" do
      create(:chore, created_by_user: user, name: "Vacuum", tag: "Home")

      expect(described_class.tagged("Workshop")).to eq([])
    end
  end

  describe ".tag_names" do
    it "lists each group once, ordered by how it reads" do
      create(:chore, created_by_user: user, name: "Vacuum", tag: "home")
      create(:chore, created_by_user: user, name: "Dishes", tag: "home")
      create(:chore, created_by_user: user, name: "Plants", tag: "Pets")
      create(:chore, created_by_user: user, name: "Nothing", tag: nil)

      expect(described_class.tag_names).to eq(["home", "Pets"])
    end
  end
end
