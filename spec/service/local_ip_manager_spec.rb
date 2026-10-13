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

  describe "whitelisting the home IP on a change" do
    before do
      caches = class_double(UserCache, set: true)
      allow(User).to receive(:me).and_return(instance_double(User, caches: caches))
      BannedIp.delete_all
    end

    it "marks the new address whitelisted so the controller never 401s the house" do
      DataStorage[:local_ip] = "97.117.17.133"

      described_class.record_ping!("97.117.20.4")

      expect(BannedIp.where(ip: "97.117.20.4", whitelisted: true)).to exist
    end

    it "un-bans the new address if it was already banned" do
      DataStorage[:local_ip] = "97.117.17.133"
      BannedIp.create!(ip: "97.117.20.4", whitelisted: false)

      described_class.record_ping!("97.117.20.4")

      expect(BannedIp.find_by(ip: "97.117.20.4").whitelisted).to be(true)
    end

    it "drops the previous address's whitelist so a reassigned IP isn't left trusted" do
      DataStorage[:local_ip] = "97.117.17.133"
      BannedIp.create!(ip: "97.117.17.133", whitelisted: true)

      described_class.record_ping!("97.117.20.4")

      expect(BannedIp.where(ip: "97.117.17.133")).not_to exist
    end

    it "leaves a real ban on the old address alone (only its whitelist is dropped)" do
      DataStorage[:local_ip] = "97.117.17.133"
      BannedIp.create!(ip: "97.117.17.133", whitelisted: false)

      described_class.record_ping!("97.117.20.4")

      expect(BannedIp.where(ip: "97.117.17.133", whitelisted: false)).to exist
    end
  end

  describe "caching the home IP for Rack::Attack" do
    before do
      # The test env uses a null cache store; Rack::Attack reads a real one.
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    end

    it "writes the reported address under the rack safelist key" do
      DataStorage[:local_ip] = "97.117.17.133"

      described_class.record_ping!("97.117.17.133")

      expect(Rails.cache.read(described_class::RACK_SAFELIST_KEY)).to eq("97.117.17.133")
    end

    it "does not cache the ignored loopback address" do
      described_class.record_ping!("::1")

      expect(Rails.cache.read(described_class::RACK_SAFELIST_KEY)).to be_nil
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
