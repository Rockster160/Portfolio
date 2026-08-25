require "rails_helper"

# `Monitor` is one socket with many listeners keyed by channel, and more than one
# thing on a page subscribes to the same channel: `icon_pool` and
# `household_icon_pool` both take "chores", `agenda_store/sync` and `agenda` both
# take "agenda", `timers/monitor` and `byte/index` both take "timers".
#
# Every fan-out over it was a plain forEach with no isolation and no dedupe, and
# both halves of that bit:
#
#   * Asking. Each subscriber is its own object, so each one asked the server
#     independently — and `resync`/`refresh` don't fetch a cached answer, they
#     run the Jil task. Two subscribers on a channel meant the task ran twice for
#     one reconnect, which is the same recomputation done again for nobody.
#
#   * Receiving. A callback that threw took the rest of the loop with it. The
#     broadcast reached whoever registered first and silently stopped; on the
#     reconnect sweep — which walks EVERY monitor on the page, not just one
#     channel — one broken cell swallowed the reconnect for all of them.
#
# The rule is that duplicate QUESTIONS collapse and duplicate DELIVERIES don't:
# every subscriber still hears about it, the server is only asked once. Nothing
# is deferred to get there — the first perform goes out synchronously and only
# copies raised in the same turn are dropped.
RSpec.describe "Monitor fan-out" do
  let(:result) { JsRunner.output("spec/javascript/monitor_fanout_runner.js") }

  describe "asking the server" do
    it "asks once when two subscribers on one channel ask together" do
      expect(result["same_channel_one_turn"]).to eq([["resync", "chores"]])
    end

    # The dedupe is per channel, not global — collapsing a whole page's worth of
    # cells into one request would leave every other cell stale.
    it "still asks each distinct channel" do
      expect(result["two_channels_one_turn"]).to eq(
        [["resync", "chores"], ["resync", "timers"]],
      )
    end

    # The window is one synchronous turn, which is exactly the width of a
    # fan-out. Anything a later turn asks for is a person or a timer wanting
    # fresh data, and suppressing that would be a cache, not a dedupe.
    it "asks again in a later turn" do
      expect(result["same_channel_later_turn"]).to eq(
        [["resync", "chores"], ["resync", "chores"]],
      )
    end

    # `execute` runs the task with executing:true and `refresh` without — they
    # are different questions about the same cell, and only `resync` repeated
    # verbatim is the redundant one.
    it "keeps resync, refresh and execute apart" do
      expect(result["distinct_actions_one_turn"]).to eq(
        [["resync", "chores"], ["refresh", "chores"], ["execute", "chores"]],
      )
    end
  end

  describe "a reconnect" do
    # The one the dashboard actually hits: the socket comes back, the sweep runs
    # every subscriber's `connected`, and each of them reaches for a resync.
    it "runs the task once no matter how many subscribers the channel has" do
      expect(result["reconnect_performs"]).to eq([["resync", "agenda"]])
    end

    # Deduping the request must not dedupe the notification — a subscriber that
    # never hears it reconnected never clears its own disconnected state.
    it "still tells every subscriber it reconnected" do
      expect(result["reconnect_reached"]).to eq(["d", "e"])
    end
  end

  describe "one subscriber blowing up" do
    it "does not stop the broadcast reaching the rest of its channel" do
      expect(result["received_after_throw"]).to eq(["first", "second"])
    end

    it "does not stop the reconnect sweep reaching other channels" do
      expect(result["sweep_after_throw"]).to eq(["printer", "uptime"])
    end
  end
end
