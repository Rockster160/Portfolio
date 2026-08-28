require "rails_helper"

# Rocco, 2026-08-28: "on a timer that Byte had set (when I didn't want him to),
# I tried swiping it away, and it disappeared, but the timer still went off at
# the end of the time (and showed itself again) instead of getting cancelled."
#
# Prod timer 94. `log_trackers` carries every request that reached Rails, and
# for that timer it holds a pause at 00:00:22 and a DELETE at 00:04:33 — four
# minutes AFTER end_at, which is the second swipe, the one he made once it had
# rung. There is no DELETE for the first swipe at all. It never left the phone.
#
# Nothing on the server was wrong: TimerFireWorker bails on an archived timer
# and Buddy::Timers.stop! kills the scheduled fire. The whole failure was that
# the chip was removed from the local store and re-rendered on the gesture, and
# the request that was supposed to make that true went into a `catch` that only
# wrote to the console. The corner of the screen said cancelled, the row was
# live, and the next hydrate quietly put it back.
#
# So a swipe is a REQUEST to cancel. Removal comes from the server.
RSpec.describe "Buddy timer swipe-to-cancel" do
  let(:result) { JsRunner.output("spec/javascript/byte_timer_swipe_runner.js") }

  describe "when the DELETE never lands" do
    it "sends the request" do
      expect(result["failed_requests"]).to eq(["DELETE /buddy/timers/94"])
    end

    # The one that matters. A chip that leaves on a failed cancel is a live
    # timer nobody is expecting, and they only find out when it rings.
    it "leaves the timer on screen instead of pretending it went" do
      expect(result["after_failed_swipe"].length).to eq(1)
      expect(result["after_failed_swipe"].first["id"]).to eq(94)
    end

    # There is no toast in Byte, so the chip coming back IS the message.
    it "flashes it so the failure is visible" do
      expect(result["after_failed_swipe"].first["pending"]).to eq("cancel-failed")
    end

    # The flash is a signal, not decoration, and what's underneath is an
    # ordinary live chip they can swipe again.
    it "settles back to a normal chip once the flash is done" do
      expect(result["after_flash_clears"].first["pending"]).to be_nil
      expect(result["after_flash_clears"].first["wired"]).to be(true)
    end
  end

  describe "when the DELETE lands" do
    it "sends the request" do
      expect(result["ok_requests"]).to eq(["DELETE /buddy/timers/94"])
    end

    it "drops the chip" do
      expect(result["after_ok_swipe"]).to be_empty
    end
  end

  describe "while the request is still out" do
    it "keeps the chip, marked as going rather than gone" do
      expect(result["in_flight"].length).to eq(1)
      expect(result["in_flight"].first["pending"]).to eq("cancel")
    end

    # A second swipe would fire a second DELETE and a tap would pause a timer
    # on its way out, so a chip mid-cancel takes no gestures at all.
    it "takes no further gestures" do
      expect(result["in_flight"].first["wired"]).to be(false)
      expect(result["second_swipe_requests"]).to be_empty
    end

    it "drops the chip once the server answers" do
      expect(result["after_release"]).to be_empty
    end
  end

  # Rocco, same day: "tapping a ringing timer should cancel it as well."
  #
  # It ran pause/resume like any other chip, which parked the thing at zero: the
  # alarm stopped (any tap anywhere does that), the countdown had nowhere left
  # to go, and the chip sat there as a ⏸ nobody could do anything with. Prod
  # timer 94 has the pause in `log_trackers` at 00:00:22, three seconds after
  # its end_at, and the swipe that actually got rid of it four minutes later.
  describe "tapping the chip that is ringing" do
    # The ring has to ARRIVE. One already past its end_at when the app opens
    # counts as acknowledged, so it never starts the alarm — hydrating a
    # ringing timer would test a tap on a chip nothing is armed around.
    it "is a real ring, with the acknowledge handler armed" do
      expect(result["ack_armed_while_ringing"]).to eq(["pointerdown"])
      expect(result["ringing_state"].length).to eq(1)
    end

    it "cancels it instead of pausing it" do
      expect(result["ringing_tap_requests"]).to eq(["DELETE /buddy/timers/94"])
    end

    it "clears the chip" do
      expect(result["after_ringing_tap"]).to be_empty
    end

    # Once the server has stamped `fired_at` the acknowledge has something to
    # confirm, so both calls go out — and the confirm landing after the cancel
    # must not put the chip back.
    it "still acknowledges the alarm when the server has caught up" do
      expect(result["fired_tap_requests"]).to eq(
        ["DELETE /buddy/timers/94", "POST /buddy/timers/94/confirm"],
      )
      expect(result["after_fired_tap"]).to be_empty
    end
  end

  # Only the ringing one changed. A tap on a chip that is still counting is
  # pause/resume exactly as it was.
  describe "tapping a chip that is still counting" do
    it "pauses it" do
      expect(result["running_tap_requests"]).to eq(["POST /buddy/timers/94/pause"])
    end

    it "keeps it on screen" do
      expect(result["after_running_tap"].length).to eq(1)
      expect(result["after_running_tap"].first["pending"]).to be_nil
    end
  end

  # Buddy::Timers.stop! broadcasts `archived`, and the cancel_timer TOOL goes
  # through the same call — so a cancel Byte does itself has to clear the chip
  # exactly as the swipe does.
  it "drops a chip the server says is archived" do
    expect(result["after_archived_broadcast"]).to be_empty
  end
end
