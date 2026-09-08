require "rails_helper"

# Home Assistant's `rest_command` gives up around ten seconds and re-sends, and
# the work behind a trigger runs INLINE in the request — five Jil tasks for one
# Whisper button press, eleven seconds on 7 Sep. The retry went all the way
# through: `action_events` 52124 and 52125 share a `timestamp` to the
# microsecond, and Rocco got two "Who did: Puppy Down?" cards for one dog.
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

  # A second, real press has its own moment. Nothing about the identity is
  # "this device sent something recently".
  it "runs a second press that carries its own moment" do
    seen = scopes_reaching_jil do
      fire(press)
      fire(press.merge(pressed_at: "2026-09-08 03:59:11.006512+00:00"))
    end

    expect(seen.length).to eq(2)
  end

  it "tells a hold apart from a click at the same instant" do
    seen = scopes_reaching_jil do
      fire(press)
      fire(press.merge(type: "click"))
    end

    expect(seen.length).to eq(2)
  end

  # Nothing to key on, so nothing is swallowed — two payloads that happen to
  # look alike are two events until one of them says otherwise.
  it "leaves a payload with no moment in it alone" do
    seen = scopes_reaching_jil do
      fire({ direction: "open" }, scope: "garage")
      fire({ direction: "open" }, scope: "garage")
    end

    expect(seen.length).to eq(2)
  end
end
