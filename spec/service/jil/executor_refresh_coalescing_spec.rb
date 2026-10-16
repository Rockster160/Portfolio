require "rails_helper"

RSpec.describe Jil::Executor do
  # A task that refreshes the same monitor view several times — the shape of a nap
  # press, which arms and cancels a run of schedules and each one recomputes the
  # Upcoming agenda — should recompute that view ONCE, at the end of the chain,
  # rather than once per refresh.
  describe "monitor refresh coalescing" do
    let(:user) { User.me }

    # Count the real dispatches (run_trigger is the inner method the coalescing
    # wrapper defers), and stand in for the monitor dispatch so no live monitor
    # task actually runs. Non-monitor triggers still dispatch for real.
    def count_monitor_dispatch
      calls = []
      allow(described_class).to(
        receive(:run_trigger).and_wrap_original { |orig, usr, trig, data, **kw|
          next (calls << trig) && [] if trig.to_s == "monitor"

          orig.call(usr, trig, data, **kw)
        },
      )
      yield
      calls.length
    end

    it "fires one dispatch for the same channel refreshed repeatedly" do
      code = <<~JIL
        a = Monitor.refresh("upcoming", "")::Monitor
        b = Monitor.refresh("upcoming", "")::Monitor
        c = Monitor.refresh("upcoming", "")::Monitor
      JIL
      expect(count_monitor_dispatch { described_class.call(user, code) }).to eq(1)
    end

    it "fires one dispatch per distinct coalesced channel" do
      code = <<~JIL
        a = Monitor.refresh("upcoming", "")::Monitor
        b = Monitor.refresh("agenda", "")::Monitor
        c = Monitor.refresh("upcoming", "")::Monitor
      JIL
      expect(count_monitor_dispatch { described_class.call(user, code) }).to eq(2)
    end

    it "broadcasts a live status feed immediately instead of coalescing it" do
      # whisper-durations is exempt: each refresh dispatches inline (3), while the
      # repeated Upcoming recompute still collapses to one — 4 in total.
      code = <<~JIL
        a = Monitor.refresh("whisper-durations", "")::Monitor
        b = Monitor.refresh("upcoming", "")::Monitor
        c = Monitor.refresh("whisper-durations", "")::Monitor
        d = Monitor.refresh("upcoming", "")::Monitor
        e = Monitor.refresh("whisper-durations", "")::Monitor
      JIL
      expect(count_monitor_dispatch { described_class.call(user, code) }).to eq(4)
    end

    it "still dispatches when a refresh happens outside any execution" do
      # No coalescing unit active here, so it runs inline immediately.
      allow(described_class).to receive(:run_trigger).and_return([])
      expect(Jil::RefreshCoalescer.active?).to be(false)
      described_class.trigger(user, :monitor, { channel: "upcoming" })
      expect(described_class).to have_received(:run_trigger).once
    end
  end
end
