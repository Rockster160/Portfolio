require "rails_helper"

# Home Assistant's `rest_command` gives up after a timeout and re-sends while the
# work behind a trigger is still running inline, so a payload that carries its
# own moment is claimed once and a re-delivery of it is dropped.
RSpec.describe "POST /jil/trigger arriving twice", type: :request do
  let(:user) { User.me }
  let!(:key) { user.api_keys.create!(name: "Shortcuts") }

  let(:press) {
    {
      device_id:   "8851af40327d79bf751c82ddc9835070",
      device_name: "Whisper Nap Button",
      pressed_at:  "2026-09-08 03:58:32.332083+00:00",
      button_id:   "28:2c:02:bf:ff:e8:fb:3c",
      battery:     "83.5",
      type:        "hold",
    }
  }

  def fire(payload, scope: "hass-button")
    post("/jil/trigger/#{scope}", params: payload.to_json, headers: {
      "HTTP_AUTHORIZATION" => "Bearer #{key.key}",
      "CONTENT_TYPE"       => "application/json",
    })
  end

  def scopes_reaching_jil
    seen = []
    allow(Jil).to receive(:trigger) { |_u, scope, data, **| seen << [scope, data] }
    yield
    seen
  end

  # The claim is a cache write, and the test store is a null store that keeps
  # nothing — so there is no claim to lose a race to unless a real one is here.
  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  it "runs the press once when the identical payload is delivered again" do
    seen = scopes_reaching_jil do
      fire(press)
      fire(press)
    end

    expect(seen.length).to eq(1)
    expect(seen.first.first).to eq("hass-button")
    expect(response).to have_http_status(:ok)
  end

  # A second, real press has its own moment, a hold differs from a click at the
  # same instant, and a payload with no moment in it has nothing to key on.
  it "runs both deliveries when they are distinct events", :aggregate_failures do
    [
      [press, press.merge(pressed_at: "2026-09-08 03:59:11.006512+00:00"), "hass-button"],
      [press, press.merge(type: "click"), "hass-button"],
      [{ direction: "open" }, { direction: "open" }, "garage"],
    ].each do |first, second, scope|
      Rails.cache.clear
      seen = scopes_reaching_jil do
        fire(first, scope: scope)
        fire(second, scope: scope)
      end

      expect(seen.length).to eq(2), "#{first} then #{second}"
    end
  end
end
