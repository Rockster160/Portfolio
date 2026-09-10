require "rails_helper"

# The cell reads one bucket — its own perceived day — so the only things that
# have to be right here are WHICH events count and WHICH day they land on.
RSpec.describe CaffeineIntake do
  let(:user) { create(:user) }
  let(:zone) { ActiveSupport::TimeZone["America/Denver"] }

  def drink(at, mg, name: "Drink")
    user.action_events.create!(name: name, timestamp: at, data: { "Caffeine" => mg })
  end

  # 10pm on the 12th and 1am on the 13th are the SAME perceived day — a late
  # soda belongs to the night it was drunk, not to the morning after it.
  it "buckets by the 3am rollover, not midnight" do
    travel_to(zone.local(2026, 9, 13, 10)) do
      drink(zone.local(2026, 9, 12, 22), 68)
      drink(zone.local(2026, 9, 13, 1), 41)
      drink(zone.local(2026, 9, 13, 9), 200)

      expect(described_class.buckets(user)).to(eq({
        "2026-09-12" => 109,
        "2026-09-13" => 200,
      }))
    end
  end

  # The milligrams are what makes it caffeine, not the name on the event.
  it "counts anything carrying milligrams, and nothing that carries none" do
    travel_to(zone.local(2026, 9, 13, 10)) do
      drink(zone.local(2026, 9, 13, 9), 95, name: "Coffee")
      drink(zone.local(2026, 9, 13, 9), 0)
      user.action_events.create!(name: "Drink", timestamp: zone.local(2026, 9, 13, 9))

      expect(described_class.buckets(user)).to(eq({ "2026-09-13" => 95 }))
    end
  end

  it "leaves out other people's drinks" do
    travel_to(zone.local(2026, 9, 13, 10)) do
      other = create(:user)
      other.action_events.create!(
        name: "Drink", timestamp: zone.local(2026, 9, 13, 9), data: { "Caffeine" => 200 },
      )

      expect(described_class.buckets(user)).to(eq({}))
    end
  end

  describe ".logged?" do
    it "is true for an event carrying milligrams" do
      expect(described_class.logged?(drink(Time.current, 68))).to(be(true))
    end

    # A correction to 0 still moves the bar, so it still has to redraw it.
    it "is true for an event that has just lost its milligrams" do
      event = drink(Time.current, 68)
      event.update!(data: {})

      expect(described_class.logged?(event)).to(be(true))
    end

    it "is false for an event that never had any" do
      event = user.action_events.create!(name: "Wordle", timestamp: Time.current)

      expect(described_class.logged?(event)).to(be(false))
    end
  end
end
