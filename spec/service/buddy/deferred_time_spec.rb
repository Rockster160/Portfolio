require "rails_helper"

RSpec.describe Buddy::DeferredTime do
  let(:user) { create(:user) }
  # A Thursday, 2:36am in Denver.
  let(:now) { Time.find_zone("America/Denver").local(2026, 11, 5, 2, 36) }

  def at(text)
    described_class.at(text, user: user, now: now)
  end

  it "reads a delay however it is said" do
    {
      "Turn off the tv in 30 minutes"     => 30.minutes,
      "turn the tv off in 30"             => 30.minutes,
      "TV off in thirty minutes"          => 30.minutes,
      "play the nap sound in an hour"     => 1.hour,
      "in half an hour start the printer" => 30.minutes,
      "in an hour and a half"             => 90.minutes,
      "in 1.5 hours"                      => 90.minutes,
      "in 90 seconds"                     => 90.seconds,
      "ten minutes from now turn it off"  => 10.minutes,
      "turn the fan off after 15 minutes" => 15.minutes,
      "in a couple minutes add milk"      => 2.minutes,
    }.each { |text, ahead| expect(at(text)).to eq(now + ahead), text }
  end

  it "reads a clock time as the next one to come" do
    zone = now.time_zone
    expect(at("start the car at 7:40")).to eq(zone.local(2026, 11, 5, 7, 40))
    expect(at("play the nap sound at 11")).to eq(zone.local(2026, 11, 5, 11, 0))
    expect(at("at 11pm turn the tv off")).to eq(zone.local(2026, 11, 5, 23, 0))
    expect(at("at 2am")).to eq(zone.local(2026, 11, 6, 2, 0))
    expect(at("at 22:15")).to eq(zone.local(2026, 11, 5, 22, 15))
    expect(at("at noon")).to eq(zone.local(2026, 11, 5, 12, 0))
  end

  it "names no time for levels, vague times, or nothing at all" do
    [
      "set the thermostat at 72",
      "set the fan at 20",
      "set the lights at 50%",
      "set the heat at 68 degrees",
      "turn the tv off tonight",
      "before bed, lock up",
      "when I get home turn on the porch light",
      "turn the tv off",
      "in 2026 we went",
      "in a bit",
    ].each { |text| expect(at(text)).to be_nil, text }
  end

  it "does not reach past a day" do
    expect(at("in 30 hours")).to be_nil
  end
end
