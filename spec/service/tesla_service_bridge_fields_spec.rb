require "rails_helper"

# Fleet-telemetry sends one field per record, so the bridge's forwarding
# whitelist is not an optimization — it decides which requested fields can
# reach Rails at all. `Gear` was requested every 5s and absent from the
# whitelist, so every gear-change record was dropped as noise and the cached
# shift stayed frozen on whatever value predated the filter (`P`, while the
# car drove at 69mph). This holds the two lists together.
RSpec.describe TeslaService do
  # The bridge tails a feed file at load, so it can't be required — read the
  # constant out of the source instead.
  def bridge_fields
    source = ::Rails.root.join("bin/tesla_telemetry_bridge.rb").read
    body = source[/^VEHICLE_FIELDS = %w\[(.*?)\]/m, 1]
    body.to_s.split.map(&:to_sym)
  end

  it "forwards every field TeslaService requests" do
    expect(bridge_fields).to match_array(::TeslaService.fields(nil).keys)
  end
end
