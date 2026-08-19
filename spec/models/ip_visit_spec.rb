RSpec.describe IpVisit, type: :model do
  describe ".record!" do
    it "creates the row and reports no prior visits for an unseen IP" do
      expect(described_class.record!("203.0.113.7")).to eq(0)

      visit = described_class.find_by(ip_address: "203.0.113.7")
      expect(visit.visit_count).to eq(1)
      expect(visit.first_seen_at).to be_present
      expect(visit.last_seen_at).to be_present
    end

    it "reports the count of visits that came before this one" do
      expect(described_class.record!("203.0.113.8")).to eq(0)
      expect(described_class.record!("203.0.113.8")).to eq(1)
      expect(described_class.record!("203.0.113.8")).to eq(2)

      expect(described_class.find_by(ip_address: "203.0.113.8").visit_count).to eq(3)
    end

    it "keeps first_seen_at fixed and moves last_seen_at forward" do
      travel_to(3.days.ago) { described_class.record!("203.0.113.9") }
      first_seen = described_class.find_by(ip_address: "203.0.113.9").first_seen_at

      described_class.record!("203.0.113.9")

      visit = described_class.find_by(ip_address: "203.0.113.9")
      expect(visit.first_seen_at).to be_within(1.second).of(first_seen)
      expect(visit.last_seen_at).to be > visit.first_seen_at
    end

    it "never creates a second row for the same IP" do
      3.times { described_class.record!("203.0.113.10") }

      expect(described_class.where(ip_address: "203.0.113.10").count).to eq(1)
    end

    it "counts each IP independently" do
      2.times { described_class.record!("203.0.113.11") }

      expect(described_class.record!("203.0.113.12")).to eq(0)
    end

    it "records nothing for a blank IP" do
      expect { expect(described_class.record!(nil)).to eq(0) }.not_to change(described_class, :count)
      expect { expect(described_class.record!("")).to eq(0) }.not_to change(described_class, :count)
    end

    # The whole reason this replaced a COUNT over log_trackers.
    it "reads nothing before it writes" do
      described_class.record!("203.0.113.13")

      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload|
        queries << payload[:sql]
      }
      described_class.record!("203.0.113.13")
      ActiveSupport::Notifications.unsubscribe(subscriber)

      statements = queries.grep(/ip_visits/i)
      expect(statements.size).to eq(1)
      expect(statements.first).to match(/INSERT INTO ip_visits/i)
    end
  end
end
