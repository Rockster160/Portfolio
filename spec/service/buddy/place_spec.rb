require "rails_helper"

# A calendar location shortened to what a briefing would say: the place's name,
# or for a bare street address, the city. The inputs are real-world shapes, since
# no two people write an address the same way.
RSpec.describe Buddy::Place do
  delegate :short, to: :described_class

  it "keeps a named place's name, dropping the city or street after it", :aggregate_failures do
    [
      ["Horsetail Falls, Alpine, UT", "Horsetail Falls"],
      # The dash people type is the same separator.
      ["Walmart- Herriman", "Walmart"],
      ["Secondhand Salamander- Taylorsville", "Secondhand Salamander"],
      ["The Garten Cider House & Bar- 417 N. 400 W. Salt Lake City", "The Garten Cider House & Bar"],
      # The house number is where the name stopped.
      ["Mountain America Exposition Center 9575 S. State St. Sandy, UT 84070", "Mountain America Exposition Center"],
    ].each do |raw, expected|
      expect(short(raw)).to eq(expected), raw
    end
  end

  # A numbered street ends at its direction; a named one ends at its type.
  it "gives the city of a street address", :aggregate_failures do
    [
      ["12723 S Park Ave, Riverton, UT  84065, United States", "Riverton"],
      # A synced calendar's newline is a separator.
      ["11820 S State St Suite 320\nDraper, UT, United States", "Draper"],
      # Google hands these back shouting.
      ["3300 N TRIUMPH BLVD STE 500, LEHI, UT 84043", "Lehi"],
      # No comma to find the city by.
      ["1061 E 1300 S Salt Lake City", "Salt Lake City"],
      ["379 S 1000 E Salt Lake City, UT 84102", "Salt Lake City"],
      ["1971 E Forest Creek Ln Cottonwood Heights, UT 84121", "Cottonwood Heights"],
      ["5719 Easton st. Taylorsville Utah 84129 United States", "Taylorsville"],
      # A suite is neither the street nor the city.
      ["11820 S State St Suite 320 Draper, UT, United States", "Draper"],
      # No city at all: the number goes anyway.
      ["4512 Bartlett Dr.", "Bartlett Dr."],
    ].each do |raw, expected|
      expect(short(raw)).to eq(expected), raw
    end
  end

  it "leaves a bare name or a link alone, and is nothing for nothing", :aggregate_failures do
    [
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
      # There is no short form of a meeting link, only a broken one.
      "https://meet.google.com/bzy-xcsh-bkj",
    ].each { |name| expect(short(name)).to eq(name) }

    expect(short(nil)).to be_nil
    expect(short("  ")).to be_nil
  end
end
