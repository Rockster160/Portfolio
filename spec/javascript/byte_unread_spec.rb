require "rails_helper"
require "json"
require "open3"

# The drawer's unread counter was a tally incremented once per BROADCAST, and a
# broadcast is not a message: a Claude turn re-sends the same row every time its
# text grows, so one reply working through a long task pushed the badge up by
# dozens while nothing had been said yet.
RSpec.describe "Byte unread counting" do
  let(:result) {
    runner = Rails.root.join("spec/javascript/byte_unread_runner.js").to_s
    stdout, stderr, status = Open3.capture3("node", runner)
    raise "runner failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  }

  describe "what counts as unread" do
    it "counts a settled inbound message" do
      expect(result["counts"]["settled_inbound"]).to be(true)
    end

    # The bug, stated directly.
    it "ignores anything still in flight" do
      counts = result["counts"]

      expect(counts["streaming"]).to be(false)
      expect(counts["pending"]).to be(false)
      expect(counts["queued"]).to be(false)
    end

    it "counts a failure, which is terminal and worth seeing" do
      expect(result["counts"]["failed"]).to be(true)
    end

    it "ignores the person's own messages" do
      expect(result["counts"]["outbound"]).to be(false)
    end

    # The other half of why a working session ran the badge up: every tool call
    # posts a receipt chip.
    it "ignores receipt chips, action pills and hidden trigger seeds" do
      counts = result["counts"]

      expect(counts["activity_chip"]).to be(false)
      expect(counts["action_chip"]).to be(false)
      expect(counts["trigger_seed"]).to be(false)
      expect(counts["hidden"]).to be(false)
    end

    it "counts what a person would actually read" do
      expect(result["counts"]["claude_reply"]).to be(true)
      expect(result["counts"]["relay"]).to be(true)
    end
  end

  describe "a Claude turn working through a long task" do
    it "stays at zero across every streaming broadcast" do
      expect(result["streaming_run_count"]).to eq(0)
    end

    it "raises no notice while it's still working" do
      expect(result["streaming_run_notices"]).to eq(0)
    end

    it "counts exactly one once it finishes" do
      expect(result["after_settle_count"]).to eq(1)
      expect(result["settle_notified"]).to be(true)
    end

    # An edit re-broadcasts a row that was already counted.
    it "does not count the same message twice" do
      expect(result["after_rebroadcast_count"]).to eq(1)
    end
  end

  describe "across conversations" do
    it "keeps a separate count per conversation" do
      expect(result["per_conversation"]).to eq("one" => 2, "two" => 1)
    end

    it "totals them for the burger badge" do
      expect(result["total"]).to eq(3)
      expect(result["conversation_count"]).to eq(2)
    end

    it "clears one thread without touching the others" do
      expect(result["after_clear"]).to eq("one" => 0, "total" => 1)
    end

    # The badge repaints on change, so a change that isn't one is a wasted
    # write on every streamed chunk.
    it "only reports a change when something really changed" do
      expect(result["change_events"]).to eq(1)
    end
  end

  # The counter lived only in the page, so a reload started it at zero and a
  # message that arrived while the app was closed was never counted at all —
  # nothing broadcasts to a page that isn't running.
  describe "surviving a reload" do
    it "takes the server's count for each thread" do
      expect(result["seeded"]).to include("one" => 3, "two" => 1, "three" => 0)
    end

    it "skips the thread being opened, which is being read right now" do
      expect(result["seeded"]["current_skipped"]).to eq(0)
    end

    it "totals them for the burger and home-screen badges" do
      expect(result["seeded"]["total"]).to eq(4)
      expect(result["seeded"]["conversations"]).to eq(2)
    end

    it "stacks live arrivals on top of the seeded count" do
      expect(result["seed_plus_live"]).to eq(4)
    end

    it "clears both halves when the thread is read" do
      expect(result["after_read"]).to eq("one" => 0, "total" => 1)
    end

    # The server's number is computed before a live message lands, so adopting
    # it blindly would drop one.
    it "does not let a stale re-seed clobber live arrivals" do
      expect(result["reseed_keeps_live"]).to eq(3)
    end

    # How a backgrounded session catches up on what it never saw broadcast.
    it "does take a newer count for a thread with nothing live" do
      expect(result["reseed_catches_up"]).to eq(5)
    end
  end

  describe "the notice preview" do
    it "strips markdown, code and shell HTML" do
      preview = result["preview"]

      expect(preview["markdown"]).to eq("Sent game_tray-vase to the printer")
      expect(preview["code"]).to eq("the listener is item:name:/x/ there")
      expect(preview["html"]).to eq("ls -la done")
    end

    it "strips a leading mood marker" do
      expect(result["preview"]["mood_marker"]).to eq("Kk! TV's off.")
    end

    it "flattens newlines into one line" do
      expect(result["preview"]["newlines"]).to eq("one two three")
    end

    it "says something for a body-less message" do
      expect(result["preview"]["empty"]).to eq("(attachment)")
    end

    it "truncates a long one" do
      expect(result["preview"]["long"].length).to be <= 90
      expect(result["preview"]["long"]).to end_with("…")
    end
  end
end
