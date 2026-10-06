require "rails_helper"

# The day's failures as rows: written from a rescue, counted by fingerprint,
# and read back as a digest by whatever reports on the day.
RSpec.describe ErrorReport do
  let(:user) { create(:user) }

  def boom(message="boom", klass: StandardError)
    klass.new(message).tap { |e| e.set_backtrace(["app/service/thing.rb:12", "app/service/caller.rb:4"]) }
  end

  describe ".record!" do
    it "writes the failure, who hit it, and where it was reported from" do
      row = described_class.record!(
        section: "buddy.turn", exception: boom("nope"), user: user, extra: { tool: :set_timer },
      )

      expect(row.section).to eq("buddy.turn")
      expect(row.error_class).to eq("StandardError")
      expect(row.message).to eq("nope")
      expect(row.backtrace).to include("app/service/thing.rb:12")
      expect(row.user_id).to eq(user.id)
      expect(row.extra).to eq({ "tool" => "set_timer" })
    end

    it "records a message with no exception behind it" do
      row = described_class.record!(section: "printer_api:103", message: "printer refused the job")

      expect(row.error_class).to be_nil
      expect(row.message).to eq("printer refused the job")
    end

    # A failure recorded and never announced is the kind nobody has seen, so
    # the absence of a channel has to be readable on the row.
    it "keeps whether it was announced anywhere" do
      announced = described_class.record!(section: "a", exception: boom, channel: "#zygy-alerts")
      quiet     = described_class.record!(section: "a", exception: boom)

      expect(announced.channel).to eq("#zygy-alerts")
      expect(quiet.channel).to be_nil
    end

    # The caller is already handling a failure. Losing the record of one is
    # better than turning one failure into two.
    it "never raises when the row can't be written" do
      allow(described_class).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "gone")

      expect { described_class.record!(section: "a", exception: boom) }.not_to raise_error
      expect(described_class.record!(section: "a", exception: boom)).to be_nil
    end
  end

  describe ".fingerprint_for" do
    # Same failure, different record id in the message: one line in a report,
    # not forty.
    it "matches the same failure across the ids that move between them" do
      first  = described_class.fingerprint_for("sync", "KeyError", "no item 1182")
      second = described_class.fingerprint_for("sync", "KeyError", "no item 1153")

      expect(first).to eq(second)
    end

    it "separates failures that differ in anything else" do
      sync  = described_class.fingerprint_for("sync", "KeyError", "no item 1182")
      turn  = described_class.fingerprint_for("turn", "KeyError", "no item 1182")
      other = described_class.fingerprint_for("sync", "TypeError", "no item 1182")

      expect([turn, other]).not_to include(sync)
    end
  end

  describe ".digest" do
    let(:span) { (2.hours.ago)..Time.current }

    it "counts the repeats and names the stretch they ran over" do
      first = nil
      travel_to(90.minutes.ago) { first = described_class.record!(section: "sync", exception: boom("no item 1")) }
      travel_to(30.minutes.ago) { described_class.record!(section: "sync", exception: boom("no item 2")) }

      entry = described_class.digest(span).first

      expect(entry[:count]).to eq(2)
      expect(entry[:section]).to eq("sync")
      expect(entry[:first_at]).to be_within(1.second).of(first.created_at)
      expect(entry[:last_at]).to be_within(1.second).of(30.minutes.ago)
    end

    it "puts the heaviest first" do
      3.times { described_class.record!(section: "sync", exception: boom("no item 1")) }
      described_class.record!(section: "turn", exception: boom("one off"))

      expect(described_class.digest(span).pluck(:section)).to eq(%w[sync turn])
    end

    it "carries a real row to read the detail off" do
      row = described_class.record!(section: "sync", exception: boom, user: user)

      entry = described_class.digest(span).first
      expect(entry[:sample_id]).to eq(row.id)
      expect(entry[:user_id]).to eq(user.id)
    end

    it "leaves out anything outside the window" do
      travel_to(3.days.ago) { described_class.record!(section: "old", exception: boom) }

      expect(described_class.digest(span)).to be_empty
    end

    it "stops at the number of distinct failures a report can be about" do
      (described_class::DIGEST_LIMIT + 4).times { |i| described_class.record!(section: "s#{i}", exception: boom) }

      expect(described_class.digest(span).length).to eq(described_class::DIGEST_LIMIT)
    end
  end
end
