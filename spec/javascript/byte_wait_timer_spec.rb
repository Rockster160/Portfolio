require "rails_helper"

# Rocco, 2026-09-04: "the '5 minutes and then whisper quiet' rendered a normal
# timer, which is fine, except that the timer went off as if I was supposed to
# go dismiss it. We do NOT want that. Showing the timer, yes. But once the timer
# ends, Byte should just quietly do whatever he was supposed to do."
#
# Prod timer 98. "Play whisper nap sound in 5 minutes" became a wait — the chip
# holding the middle of a sequence, with the sound queued behind it — and the
# chip was indistinguishable from a kitchen timer: it blared at zero and its
# `confirmed_at` lands two seconds later, which is the tap that shut it up. The
# sound was already playing by then. Nothing was being asked of him.
#
# So the flag rides on the serialized timer (Buddy::Timers::WAIT) and the client
# reads it BEFORE the countdown ends — it rings off `end_at`, seconds ahead of
# the server's fire, so learning about it at fire time would be too late.
RSpec.describe "Buddy wait-timer chips" do
  let(:result) { JsRunner.output("spec/javascript/byte_wait_timer_runner.js") }

  # The chip was never the complaint. It is the only sign the delay is real.
  it "shows a wait while it counts, like any other chip" do
    expect(result["counting"].length).to eq(1)
    expect(result["counting"].first["state"]).to eq("running")
    expect(result["counting"].first["readout"]).to eq("4:00")
  end

  describe "when the wait reaches zero" do
    it "doesn't ring, and arms nothing waiting to be tapped" do
      expect(result["wait_ack_armed"]).to be_empty
    end

    # No ⏰, no fired face. It has finished, not gone off.
    it "keeps the plain chip rather than the alarm one" do
      expect(result["wait_at_zero"].first["state"]).to eq("running")
      expect(result["wait_at_zero"].first["icon"]).to eq("⏲")
      expect(result["wait_at_zero"].first["readout"]).to eq("0:00")
    end

    # A tap on a spent wait would DELETE a timer that has already done its job,
    # and the archive is on its way regardless.
    it "takes no gestures" do
      expect(result["wait_at_zero"].first["wired"]).to be(false)
      expect(result["wait_requests"]).to be_empty
    end

    # Buddy::Timers.on_fired archives it as soon as the held step runs, so
    # nobody has to clear it.
    it "leaves on its own when the server archives it" do
      expect(result["after_archive"]).to be_empty
    end
  end

  # The half that must not have changed. A countdown they set themselves still
  # rings and still wants acknowledging.
  describe "an ordinary countdown" do
    it "still rings" do
      expect(result["plain_ack_armed"]).to eq(["pointerdown"])
      expect(result["plain_at_zero"].first["state"]).to eq("fired")
      expect(result["plain_at_zero"].first["icon"]).to eq("⏰")
    end
  end

  # A spent wait sits at the top of the stack (due sorts first) for as long as
  # it takes the archive to arrive. It must not swallow a real timer beside it.
  describe "a wait sitting next to a timer that is ringing" do
    it "stays silent on its own and lets the real one ring" do
      expect(result["mixed_ack_after_wait"]).to be_empty
      expect(result["mixed_ack_after_plain"]).to eq(["pointerdown"])
    end

    it "shows both, each with its own face" do
      expect(result["mixed"].pluck("state")).to eq(%w[running fired])
    end
  end
end
