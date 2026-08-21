require "rails_helper"

RSpec.describe Buddy::UsageSpool do
  let(:user) { User.me }
  let(:spool_dir) { Rails.root.join("tmp/usage_spool_spec") }

  before do
    FileUtils.rm_rf(spool_dir)
    described_class.instance_variable_set(:@origin_id, nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("BUDDY_USAGE_SPOOL_DIR").and_return(spool_dir.to_s)
    allow(ENV).to receive(:[]).with("BUDDY_USAGE_SPOOL").and_return("1")
  end

  after { FileUtils.rm_rf(spool_dir) }

  def usage(**overrides)
    BuddyUsage.create!({
      user:                user,
      kind:                :eval,
      env:                 :development,
      model:               "gpt-5.4-mini",
      input_tokens:        1_000,
      cached_input_tokens: 800,
      output_tokens:       100,
      reasoning_tokens:    20,
      cost_micros:         1_234,
    }.merge(overrides))
  end

  describe ".append!" do
    it "writes one line per call, carrying where it came from" do
      described_class.append!(usage)

      expect(described_class.pending.length).to eq(1)
      expect(described_class.pending.first).to include(
        env:         "development",
        kind:        "eval",
        model:       "gpt-5.4-mini",
        cost_micros: 1_234,
        username:    user.username,
      )
    end

    # Those ids mean something else in the database this is headed for.
    it "leaves the conversation and message behind" do
      convo = user.byte_conversations.create!(mode: :buddy, name: "Buddy")
      described_class.append!(usage(byte_conversation: convo))

      expect(described_class.pending.first.keys).not_to include(:byte_message_id, :byte_conversation_id)
    end

    it "appends rather than replacing" do
      3.times { described_class.append!(usage) }

      expect(described_class.pending.length).to eq(3)
      expect(described_class.pending.pluck(:origin_uid).uniq.length).to eq(3)
    end

    it "ignores a row that arrived from somewhere else" do
      described_class.append!(usage(origin_uid: "someone-else:development:9:2026-08-01T00:00:00.000Z"))

      expect(described_class.pending).to be_empty
    end

    it "records nothing when spooling is off" do
      allow(ENV).to receive(:[]).with("BUDDY_USAGE_SPOOL").and_return("0")

      described_class.append!(usage)

      expect(described_class.pending).to be_empty
    end
  end

  describe ".spool?" do
    def spooling_in?(name)
      allow(ENV).to receive(:[]).with("BUDDY_USAGE_SPOOL").and_return(nil)
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new(name))
      described_class.spool?
    end

    it "is on for an ordinary day at the laptop" do
      expect(spooling_in?("development")).to be(true)
    end

    # Production writes straight to the database everything else is trying to
    # reach, and the suite's token counts are invented.
    it "is off where there is nothing to hand over" do
      expect(spooling_in?("production")).to be(false)
      expect(spooling_in?("test")).to be(false)
    end
  end

  describe ".uid_for" do
    # The id alone is not enough, and the reason is two DATABASES rather than
    # two rows. Dev is a restore of a production backup, so the laptop's eval
    # rows sit at ids production had already given to different calls of its
    # own — 1925 up, in the 20 Aug restore. Sending one under a bare id would
    # have it deduped against a real row and its spend dropped on the floor.
    it "separates two rows that share an id but were written by different databases" do
      first  = usage
      second = usage(created_at: first.created_at - 3.hours)
      second.id = first.id

      expect(described_class.uid_for(second)).not_to eq(described_class.uid_for(first))
    end

    it "is the same every time for the same row" do
      row = usage

      expect(described_class.uid_for(row)).to eq(described_class.uid_for(row.reload))
    end
  end

  describe ".origin_id" do
    it "survives across calls so a reset database can't reissue a uid" do
      first = described_class.origin_id
      described_class.instance_variable_set(:@origin_id, nil)

      expect(described_class.origin_id).to eq(first)
    end
  end

  describe ".archive!" do
    it "moves the file aside and keeps its uids known" do
      described_class.append!(usage)
      uid = described_class.pending.first[:origin_uid]

      archived = described_class.archive!("20260821120000")

      expect(described_class.pending).to be_empty
      expect(archived.read).to include(uid)
      expect(described_class.spooled_uids).to include(uid)
    end
  end

  describe ".spooled_uids" do
    it "covers what is waiting as well as what has gone" do
      described_class.append!(usage)
      described_class.archive!("20260821120000")
      described_class.append!(usage)

      expect(described_class.spooled_uids.length).to eq(2)
    end
  end
end
