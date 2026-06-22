require "rails_helper"

RSpec.describe Jarvis::Durations do
  describe ".extract" do
    {
      "for 20 minutes"            => 20,
      "for 20 min"                => 20,
      "for 20m"                   => 20,
      "for 1 hour"                => 60,
      "for an hour"               => 60,
      "for a minute"              => 1,
      "for 1h"                    => 60,
      "for 1 hr"                  => 60,
      "for 1.5 hours"             => 90,
      "for 1.5h"                  => 90,
      "for 90m"                   => 90,
      "1h 30m"                    => 90,
      "1h30m"                     => 90,
      "1 hour 30 minutes"         => 90,
      "1 hour and 30 minutes"     => 90,
      "for half hour"             => 30,
      "30 minute walk"            => 30,
      "20 minutes at Costco"      => 20,
      "Costco for 20 minutes"     => 20,
      "agenda add meeting"        => 0,
      "at 4"                      => 0,
      "at 4pm"                    => 0,
      ""                          => 0,
      "10 sec"                    => 0, # 10/60 → rounds to 0
      "30 sec"                    => 1, # rounds to 1
      # Word qty ("a"/"an"/"half") must be space-separated from its unit,
      # so AM-suffixed times and -ham/-sam words don't get clipped.
      "Coffee tomorrow at 9am"    => 0,
      "Standup at 10am"           => 0,
      "I am hungry"               => 0,
      "Eat ham at 5pm"            => 0,
      "Sam's birthday Friday"     => 0,
      "Birmingham"                => 0,
      "Standup at 10am for 30 m"  => 30,
    }.each do |input, expected|
      it "extracts #{expected} minutes from #{input.inspect}" do
        expect(described_class.extract(input)).to eq(expected)
      end
    end

    it "ignores duration-like substrings inside words" do
      expect(described_class.extract("Costcomeeting agent7minutes")).to eq(0)
    end
  end

  describe ".strip" do
    {
      "Costco for 20 minutes"           => "Costco",
      "20 minutes at Costco"            => "at Costco",
      "for 1h 30m hospital visit"       => "hospital visit",
      "30 minute walk"                  => "walk",
      "agenda add meeting at home"      => "agenda add meeting at home",
      "buy milk for 5 min"              => "buy milk",
      "for 90m"                         => "",
      # AM-suffixed times and -ham/-sam words survive strip intact.
      "Coffee tomorrow at 9am"          => "Coffee tomorrow at 9am",
      "Eat ham at 5pm"                  => "Eat ham at 5pm",
      "Sam's birthday Friday"           => "Sam's birthday Friday",
    }.each do |input, expected|
      it "strips to #{expected.inspect} from #{input.inspect}" do
        expect(described_class.strip(input)).to eq(expected)
      end
    end
  end
end
