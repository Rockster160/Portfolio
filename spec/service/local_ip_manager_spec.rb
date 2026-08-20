require "rails_helper"

RSpec.describe LocalIpManager do
  before do
    DataStorage.where(name: [:local_ip, described_class::SEEN_AT_KEY]).delete_all
    allow(Jarvis).to receive(:say)
  end

  describe ".record_ping!" do
    # The reason the stamp exists at all: `local_ip=` writes nothing when the
    # address is unchanged, so a healthy home network left no trace and a dead
    # one left the same trace. Prod could never tell them apart.
    it "stamps the check-in even when the address hasn't moved" do
      DataStorage[:local_ip] = "97.117.17.133"
      expect { described_class.record_ping!("97.117.17.133") }.to change(described_class, :last_seen_at).from(nil)
      expect(DataStorage[:local_ip]).to eq("97.117.17.133")
    end

    it "still records the new address when it does move" do
      DataStorage[:local_ip] = "97.117.17.133"
      caches = class_double(UserCache, set: true)
      allow(User).to receive(:me).and_return(instance_double(User, caches: caches))

      described_class.record_ping!("10.0.0.9")

      expect(DataStorage[:local_ip]).to eq("10.0.0.9")
      expect(described_class.last_seen_at).to be_within(5.seconds).of(Time.current)
    end

    it "stamps the check-in even for the ignored loopback address" do
      described_class.record_ping!("::1")
      expect(described_class.last_seen_at).to be_within(5.seconds).of(Time.current)
      expect(DataStorage[:local_ip]).to be_blank
    end
  end

  describe ".last_seen_at" do
    it "is nil before anything has ever checked in" do
      expect(described_class.last_seen_at).to be_nil
    end

    it "round-trips through DataStorage as a real time" do
      moment = 3.hours.ago
      DataStorage[described_class::SEEN_AT_KEY] = moment.to_i
      expect(described_class.last_seen_at).to be_within(1.second).of(moment)
    end
  end
end
