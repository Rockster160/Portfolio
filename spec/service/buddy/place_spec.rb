require "rails_helper"

# The 9 Sep briefing: "Monday's plunge with Wil is still on the board for
# Horsetail Falls, Alpine, UT" — a mailing label for a canyon he has driven to
# a hundred times. Rocco: "That should be AT Horsetail Falls... I need a
# briefing, not a detailed breakdown."
#
# Every string here is a real `agenda_items.location` out of production, which
# is the only way to know the rule holds: a calendar location is whatever got
# typed or synced, and no two people write an address the same way.
RSpec.describe Buddy::Place do
  delegate :short, to: :described_class

  # The one from the briefing, and the shape most of his own entries take.
  describe "a named place with a city after it" do
    it "keeps the name" do
      expect(short("Horsetail Falls, Alpine, UT")).to eq("Horsetail Falls")
    end

    it "reads the dash people type as the same separator" do
      expect(short("Walmart- Herriman")).to eq("Walmart")
      expect(short("Secondhand Salamander- Taylorsville")).to eq("Secondhand Salamander")
      expect(short("The Garten Cider House & Bar- 417 N. 400 W. Salt Lake City"))
        .to eq("The Garten Cider House & Bar")
    end

    # A name with the street stuck on the end. The house number is where the
    # name stopped.
    it "drops a street that got typed after the name" do
      expect(short("Mountain America Exposition Center 9575 S. State St. Sandy, UT 84070"))
        .to eq("Mountain America Exposition Center")
    end
  end

  # "You have a hair appointment in Sandy today" — his own example of what he
  # wants instead. An address that leads with a house number has no name to
  # give, so the city is the half worth saying.
  describe "a street address" do
    it "gives the city" do
      expect(short("12723 S Park Ave, Riverton, UT  84065, United States")).to eq("Riverton")
    end

    it "reads a synced calendar's newline as a separator" do
      expect(short("11820 S State St Suite 320\nDraper, UT, United States")).to eq("Draper")
    end

    # Google hands these back shouting. Said as written it reads like an
    # abbreviation nobody expands.
    it "stops shouting the city" do
      expect(short("3300 N TRIUMPH BLVD STE 500, LEHI, UT 84043")).to eq("Lehi")
    end

    # No comma anywhere to find the city by. Rocco: "should just say 'Salt Lake
    # City'. I don't need nor want the full address."
    it "finds the city with no comma to find it by" do
      expect(short("1061 E 1300 S Salt Lake City")).to eq("Salt Lake City")
      expect(short("379 S 1000 E Salt Lake City, UT 84102")).to eq("Salt Lake City")
    end

    # The two ways a street ends. A numbered street ends at its direction; a
    # named one ends at its type.
    it "reads a named street the same way" do
      expect(short("1971 E Forest Creek Ln Cottonwood Heights, UT 84121")).to eq("Cottonwood Heights")
      expect(short("5719 Easton st. Taylorsville Utah 84129 United States")).to eq("Taylorsville")
    end

    # A suite is neither the street nor the city, and left in it made the city
    # read as "Suite 320 Draper".
    it "steps over a suite on the way to the city" do
      expect(short("11820 S State St Suite 320 Draper, UT, United States")).to eq("Draper")
    end

    # There is no city in this one at all. The number goes anyway: "street
    # numbers and ... the zip and state and all of that excessive info that I
    # already know."
    it "drops the house number when there is no city to give" do
      expect(short("4512 Bartlett Dr.")).to eq("Bartlett Dr.")
    end
  end

  describe "what it leaves alone" do
    it "does not touch a place that is already just a name" do
      names = [
        "Costco",
        "Early Light Academy",
        "Lucky Ones Coffee",
        "Utah State Fair Park",
        "OCS-3-Large Conference Room (100)",
        "Church and state",
        "home",
        "Work",
        "Zoom",
        "Virtual",
        "Unknown",
        "Riverton",
      ]

      names.each { |name| expect(short(name)).to eq(name) }
    end

    # There is no short form of a meeting link, only a broken one.
    it "does not touch a link" do
      link = "https://meet.google.com/bzy-xcsh-bkj"

      expect(short(link)).to eq(link)
    end

    it "is nothing for nothing" do
      expect(short(nil)).to be_nil
      expect(short("  ")).to be_nil
    end
  end
end
