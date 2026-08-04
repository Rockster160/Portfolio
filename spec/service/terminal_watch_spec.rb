require "rails_helper"

RSpec.describe TerminalWatch do
  let(:user) { User.me }
  let(:watch_id) { "abc-123" }

  # Test env cache is :null_store — swap in a real in-memory store so the
  # register → dispatch round-trip actually persists.
  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(::MonitorChannel).to receive(:broadcast_to)
  end

  describe ".register + .dispatch" do
    it "broadcasts a hit when a later trigger matches the watched listener" do
      described_class.register(user, watch_id, "hass-sensor:location:doorbell")

      described_class.dispatch(user, :"hass-sensor", { location: "doorbell" })

      expect(::MonitorChannel).to have_received(:broadcast_to).with(
        user,
        hash_including(id: :"terminal-watch", type: :hit, watch_id: watch_id, scope: "hass-sensor")
      )
    end

    it "does not broadcast when the trigger scope differs" do
      described_class.register(user, watch_id, "hass-sensor:location:doorbell")

      described_class.dispatch(user, :email, { from: "doorbell" })

      expect(::MonitorChannel).not_to have_received(:broadcast_to)
    end

    it "does not broadcast when the listener filter does not match the payload" do
      described_class.register(user, watch_id, "hass-sensor:location:doorbell")

      described_class.dispatch(user, :"hass-sensor", { location: "garage" })

      expect(::MonitorChannel).not_to have_received(:broadcast_to)
    end

    it "does not broadcast to a different user" do
      other = FactoryBot.create(:user)
      described_class.register(user, watch_id, "hass-sensor:location:doorbell")

      described_class.dispatch(other, :"hass-sensor", { location: "doorbell" })

      expect(::MonitorChannel).not_to have_received(:broadcast_to)
    end
  end

  describe ".unregister" do
    it "stops the watch from matching" do
      described_class.register(user, watch_id, "hass-sensor:location:doorbell")
      described_class.unregister(user, watch_id)

      described_class.dispatch(user, :"hass-sensor", { location: "doorbell" })

      expect(::MonitorChannel).not_to have_received(:broadcast_to)
    end
  end

  describe "lease expiry" do
    it "drops a watch whose lease has lapsed" do
      described_class.register(user, watch_id, "hass-sensor:location:doorbell")

      travel_to((described_class::LEASE + 5).seconds.from_now) do
        described_class.dispatch(user, :"hass-sensor", { location: "doorbell" })
      end

      expect(::MonitorChannel).not_to have_received(:broadcast_to)
    end

    it "keeps the watch alive across a heartbeat" do
      described_class.register(user, watch_id, "hass-sensor:location:doorbell")

      travel_to((described_class::LEASE - 5).seconds.from_now) do
        described_class.heartbeat(user, watch_id)
      end
      travel_to((described_class::LEASE + 5).seconds.from_now) do
        described_class.dispatch(user, :"hass-sensor", { location: "doorbell" })
      end

      expect(::MonitorChannel).to have_received(:broadcast_to).once
    end
  end

  describe "dispatch bail" do
    it "is a no-op with an empty registry" do
      expect { described_class.dispatch(user, :"hass-sensor", { location: "doorbell" }) }.not_to raise_error
      expect(::MonitorChannel).not_to have_received(:broadcast_to)
    end
  end
end
