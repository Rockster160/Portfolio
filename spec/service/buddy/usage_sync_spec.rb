require "rails_helper"

RSpec.describe Buddy::UsageSync do
  let(:user) { User.me }
  let(:spool_dir) { Rails.root.join("tmp/usage_sync_spec") }

  before do
    FileUtils.rm_rf(spool_dir)
    Buddy::UsageSpool.instance_variable_set(:@origin_id, nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("BUDDY_USAGE_SPOOL_DIR").and_return(spool_dir.to_s)
    allow(ENV).to receive(:[]).with("BUDDY_USAGE_SPOOL").and_return("1")
  end

  after { FileUtils.rm_rf(spool_dir) }

  def usage(**overrides)
    BuddyUsage.create!({
      user:        user,
      kind:        :eval,
      env:         :development,
      model:       "gpt-5.4-mini",
      cost_micros: 1_234,
    }.merge(overrides))
  end

  def answer(created:, received: created, duplicate: 0, skipped: 0)
    { data: { received: received, created: created, duplicate: duplicate, skipped: skipped } }
  end

  describe ".call" do
    it "sends what is waiting and files the file away" do
      2.times { Buddy::UsageSpool.append!(usage) }
      allow(ProdApi).to receive(:post).and_return(answer(created: 2))

      result = described_class.call

      expect(ProdApi).to have_received(:post).once
      expect(result).to include(rows: 2, created: 2)
      expect(Buddy::UsageSpool.pending).to be_empty
      expect(result[:archived].read.lines.length).to eq(2)
    end

    it "sends the rows themselves, not the local ids" do
      Buddy::UsageSpool.append!(usage)
      allow(ProdApi).to receive(:post).and_return(answer(created: 1))

      described_class.call

      expect(ProdApi).to have_received(:post).with(
        :buddy_usages,
        hash_including(usages: [hash_including(env: "development", kind: "eval", cost_micros: 1_234)]),
        content_type: "application/json",
      )
    end

    it "splits a long spool into batches and adds the answers up" do
      3.times { Buddy::UsageSpool.append!(usage) }
      allow(ProdApi).to receive(:post).and_return(answer(created: 1, duplicate: 1))

      result = described_class.call(batch: 1)

      expect(ProdApi).to have_received(:post).exactly(3).times
      expect(result).to include(created: 3, duplicate: 3)
    end

    # A file filed away as done is spend nobody can get back.
    it "leaves the spool alone when a batch fails" do
      2.times { Buddy::UsageSpool.append!(usage) }
      allow(ProdApi).to receive(:post).and_raise(RestClient::BadGateway)

      expect { described_class.call }.to raise_error(RestClient::BadGateway)
      expect(Buddy::UsageSpool.pending.length).to eq(2)
    end

    it "treats an answer it can't read as a failure" do
      Buddy::UsageSpool.append!(usage)
      allow(ProdApi).to receive(:post).and_return("<html>502</html>")

      expect { described_class.call }.to raise_error(described_class::Error)
      expect(Buddy::UsageSpool.pending.length).to eq(1)
    end

    it "does nothing at all with an empty spool" do
      allow(ProdApi).to receive(:post)

      expect(described_class.call).to include(rows: 0)
      expect(ProdApi).not_to have_received(:post)
    end
  end

  describe ".backfill!" do
    it "spools rows written before there was anywhere to send them" do
      usage
      usage

      expect(described_class.backfill!.length).to eq(2)
      expect(Buddy::UsageSpool.pending.length).to eq(2)
    end

    it "does not send the same afternoon twice" do
      Buddy::UsageSpool.append!(usage)

      expect(described_class.backfill!).to be_empty
    end

    it "skips what has already gone" do
      Buddy::UsageSpool.append!(usage)
      Buddy::UsageSpool.archive!("20260821120000")

      expect(described_class.backfill!).to be_empty
    end

    it "leaves out rows that arrived from somewhere else" do
      usage(origin_uid: "elsewhere:development:1:2026-08-01T00:00:00.000Z")

      expect(described_class.backfill!).to be_empty
    end

    # The fake client invents its token counts, so they are not money.
    it "leaves out the suite's own rows" do
      usage(env: :test)

      expect(described_class.backfill!).to be_empty
    end

    # Development here is a restore of a production backup: those rows were
    # spent by production and are already counted there.
    it "leaves out rows a restored backup brought in" do
      usage(env: :production)

      expect(described_class.backfill!).to be_empty
    end

    it "can be held to the last few days" do
      usage
      old = usage
      old.update_column(:created_at, 40.days.ago)

      expect(described_class.backfill!(days: 30).length).to eq(1)
    end
  end
end
