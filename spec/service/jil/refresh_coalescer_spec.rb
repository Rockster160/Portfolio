require "rails_helper"

RSpec.describe Jil::RefreshCoalescer do
  after { Thread.current[described_class::KEY] = nil }

  describe "outside a unit of work" do
    it "is inactive and registering is a no-op — callers run inline" do
      expect(described_class.active?).to be(false)
      ran = false
      described_class.register(:k) { ran = true }
      expect(ran).to be(false) # register never runs it; the caller does, inline
    end
  end

  describe "#coalesce" do
    it "activates a buffer for the duration of the block and clears it after" do
      expect(described_class.active?).to be(false)
      described_class.coalesce { expect(described_class.active?).to be(true) }
      expect(described_class.active?).to be(false)
    end

    it "defers registered refreshes and flushes them once at the end" do
      calls = []
      described_class.coalesce {
        described_class.register(:a) { calls << :a }
        expect(calls).to be_empty # nothing runs mid-chain
      }
      expect(calls).to eq([:a])
    end

    it "dedupes by key so an identical refresh raised N times runs once" do
      count = 0
      described_class.coalesce {
        3.times { described_class.register(:same) { count += 1 } }
      }
      expect(count).to eq(1)
    end

    it "keeps distinct keys as distinct refreshes, in registration order" do
      order = []
      described_class.coalesce {
        described_class.register(:a) { order << :a }
        described_class.register(:b) { order << :b }
      }
      expect(order).to eq([:a, :b])
    end

    it "flushes even when the chain raises — the final update is never lost" do
      ran = false
      expect {
        described_class.coalesce {
          described_class.register(:a) { ran = true }
          raise "boom"
        }
      }.to raise_error("boom")
      expect(ran).to be(true)
      expect(described_class.active?).to be(false)
    end

    it "isolates a failing refresh so the rest still flush" do
      ran = []
      described_class.coalesce {
        described_class.register(:bad) { raise "nope" }
        described_class.register(:good) { ran << :good }
      }
      expect(ran).to eq([:good])
    end
  end

  describe "nesting" do
    it "lets the outermost call own the single flush" do
      calls = []
      described_class.coalesce {
        described_class.register(:outer) { calls << :outer }
        described_class.coalesce {
          # nested: still the same active buffer, no flush here
          described_class.register(:inner) { calls << :inner }
          expect(calls).to be_empty
        }
        expect(calls).to be_empty # inner did not flush
      }
      expect(calls).to eq([:outer, :inner])
    end
  end
end
