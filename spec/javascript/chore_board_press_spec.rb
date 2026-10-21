require "rails_helper"

# What a press on the chore board looks like before the server has answered.
#
# The bargain is /chores/today's: the tap is painted IMMEDIATELY from a locally
# predicted state and nothing spins. That page's offline queue is explicit
# about why — its items are "silent by default so a momentarily slow happy-path
# drain doesn't flash a 'pending' badge in the user's face" — and a board is
# pressed several times in a row while walking past, so a flicker on each one
# is worse than no feedback at all. What says the touch landed is the ring
# moving under the finger; the dim says it is still in the air; the amber dot
# says it genuinely hasn't gone through.
RSpec.describe "Chore board presses" do
  let(:result) { JsRunner.output("spec/javascript/chore_board_press_runner.js") }

  describe "an untouched chore" do
    it "offers both skips and no way back" do
      expect(result["controls_open"]).to eq(
        "skip" => false, "cycle" => false, "undo" => true,
      )
    end
  end

  describe "while a press is in the air" do
    # The whole point. 1 of 3 means a dashoffset of 66.67 on a pathLength of
    # 100, and it is there before the request has come back.
    it "has already moved the ring" do
      expect(result.dig("mid_flight", "ringOffset").to_f).to be_within(0.01).of(66.67)
      expect(result.dig("mid_flight", "count")).to eq("1/3")
    end

    it "marks the cell as sending" do
      expect(result.dig("mid_flight", "sending")).to eq("true")
      expect(result.dig("mid_flight", "syncPending")).to eq("false")
    end

    it "stops marking it once the answer lands, keeping what it predicted" do
      expect(result.dig("after_answer", "sending")).to eq("false")
      expect(result.dig("after_answer", "count")).to eq("1/3")
    end
  end

  # A chore with a target of three gets pressed three times faster than any of
  # them come back. Two failures were possible here and both are checked: the
  # disc refusing a press while one was in flight, and the first answer back
  # clearing the in-flight mark that still belonged to the second.
  describe "presses faster than answers" do
    it "sends every one of them" do
      expect(result["burst_requests"]).to eq(2)
    end

    it "keeps the mark up until the last one is answered" do
      expect(result.dig("burst_mid", "sending")).to eq("true")
      expect(result.dig("burst_after", "sending")).to eq("false")
    end

    it "fills the ring tap by tap to the target" do
      expect(result.dig("burst_mid", "count")).to eq("3/3")
      expect(result.dig("burst_after", "ringOffset")).to eq("0")
      expect(result.dig("burst_after", "state")).to eq("done")
    end

    it "takes the skips away once there is nothing left to skip" do
      expect(result["controls_done"]).to eq("skip" => true, "undo" => true)
    end
  end

  describe "a press that fails" do
    # Rolling the circle back would say the press was ignored, which is the one
    # thing that isn't true — it happened, and it is being retried.
    it "keeps what it predicted on screen" do
      expect(result.dig("failed", "state")).to eq("dismissed")
      expect(result["server_never_got_it"]).to be(false)
    end

    it "says so with the dot rather than with the dim" do
      expect(result.dig("failed", "syncPending")).to eq("true")
      expect(result.dig("failed", "sending")).to eq("false")
    end

    it "goes again when the socket comes back, and clears the dot" do
      expect(result["retry_requests"]).to eq(["POST /chores/items/2/dismiss"])
      expect(result["server_has_it_now"]).to be(true)
      expect(result.dig("after_retry", "syncPending")).to eq("false")
    end

    # The retry has to finish BEFORE the resync, or the server's old state is
    # painted over the prediction the retry was in the middle of confirming.
    it "is still shown as away after the resync that follows the retry" do
      expect(result.dig("after_retry", "state")).to eq("dismissed")
    end

    it "is kept while a press on another chore goes out and lands" do
      expect(result["failure_before"]).to eq("true")
      expect(result["failure_survived_other_press"]).to eq("true")
      expect(result["other_press_landed"]).to be(true)
    end
  end

  # Like the Chores page: a press is written down before it is sent, so one
  # made with no connection shows as done, says it hasn't gone through, and
  # goes out with the time it was pressed once the server can be reached.
  describe "a press with no connection" do
    it "shows as done, with the dot, and keeps it with when it was pressed" do
      expect(result["offline_press"]).to include("state" => "done", "syncPending" => "true", "sending" => "false")
      expect(result.dig("offline_press", "kept")).to eq(["complete"])
      expect(result.dig("offline_press", "pressed_at")).to be(true)
    end

    it "leaves every circle standing when a refresh can't reach the server" do
      expect(result["offline_resync_cells"]).to eq(6)
    end

    it "goes out once the connection is back, and clears the dot" do
      expect(result["back_online"]).to include("state" => "done", "syncPending" => "false", "server" => 1)
    end
  end

  describe "a chore already put away" do
    it "ignores a press on its circle" do
      expect(result["press_while_away"]).to eq(0)
    end

    it "offers Undo in place of the skips" do
      expect(result["controls_away"]).to eq("skip" => true, "undo" => false)
    end

    it "comes back on Undo" do
      expect(result.dig("after_undo", "state")).to eq("open")
    end
  end

  # A trigger (routine) sits on the same board as a tap-to-fire circle. It has
  # no occurrence to settle, so it wears none of the chore machinery.
  describe "a trigger on the board" do
    it "draws no ring, no count and no skip/undo - just the circle" do
      expect(result["trigger_controls"]).to eq(
        "ring" => true, "count" => true, "skip" => true, "undo" => true,
        "state" => "trigger",
      )
    end

    it "fires the routine's run endpoint and touches no chore endpoint" do
      expect(result["fire_requests"]).to include("POST /buddy/routines/3/run")
      expect(result["fire_hit_no_chore_endpoint"]).to be(true)
    end
  end

  # A credit button is stateless like a trigger, but a press completes a chore on
  # someone's behalf through its own endpoint.
  describe "a credit button on the board" do
    it "draws no ring and no skip corner" do
      expect(result["credit_controls"]).to eq(
        "ring" => true, "skip" => true, "state" => "credit",
      )
    end

    it "presses its own credit endpoint and touches no chore endpoint" do
      expect(result["credit_requests"]).to include("POST /byte/board/buttons/7/press")
      expect(result["credit_hit_no_chore_endpoint"]).to be(true)
    end
  end

  # A task button's endpoint answers `head :ok` with no body. Reading that as
  # JSON threw, filed a press that worked as failed (the amber dot), and queued
  # the task to run again on the next reconnect.
  describe "a task button" do
    it "takes an empty answer as success" do
      expect(result["task_press"]["requests"]).to eq(["POST /byte/board/tasks/8/press"])
      expect(result["task_press"]["syncPending"]).to eq("false")
    end
  end

  # Read the way the list pages read a task's tile.
  describe "a task button wearing its tile" do
    it "puts the tile's text on the disc, at its size, and keeps its own name under it" do
      expect(result["tile_text"]).to include(
        "title" => "Garage", "text" => "Close Garage", "words" => "true", "fontSize" => "20px",
      )
    end

    it "draws a stack as one glyph" do
      expect(result["tile_stack"]).to include("stacked" => "stacked-emoji", "words" => "false")
    end

    it "draws an icon it sends in place of the text, as a picture, and takes a label" do
      expect(result.dig("tile_icon", "img")).to start_with("data:image/svg+xml")
      expect(result.dig("tile_icon", "title")).to eq("Garage door")
    end
  end

  describe "an item from the board's list" do
    it "puts its name on the disc, or its emoji with the name underneath" do
      expect(result.dig("list_open", "chairs")).to include(
        "state" => "open", "priority" => "high", "face" => "Chairs", "title" => "", "undoHidden" => true,
      )
      expect(result.dig("list_open", "keys")).to include("face" => "🔑", "title" => "Keys")
    end

    it "fills its ring as soon as it's pressed, and offers Undo once checked" do
      expect(result["list_mid"]).to include("state" => "done", "sending" => "true", "ring" => "0")
      expect(result["list_after"]).to include("state" => "done", "sending" => "false", "undoHidden" => false)
    end

    it "sends nothing for a second press on a checked item" do
      expect(result["list_pressed_again"]).to eq(0)
    end

    it "goes back on the list on Undo" do
      expect(result["list_undone"]).to include(
        "state" => "open", "ring" => "100", "request" => "DELETE /byte/board/list_items/11/check",
      )
    end

    it "says in words how long checked items stay" do
      expect(result.dig("clear_after", "summaries")).to eq([
        "GO, checked items leave after 30 seconds",
        "GO, checked items leave after 5 minutes",
        "GO, checked items leave after 1 hour",
        "GO, checked items leave after 2 hours",
        "GO, checked items leave after 1 minute, 30 seconds",
        "GO, checked items leave straight away",
        "GO, checked items leave at the end of the day",
      ])
      expect(result.dig("clear_after", "none")).to eq("None")
    end

    it "leaves the board when its time is up" do
      expect(result["list_before_leaving"]).to be(true)
      expect(result["list_left"]).to be(true)
    end
  end

  # The pad is never emptied and redrawn: a button arriving or leaving moves
  # cells in and out around the ones already standing.
  describe "the set changing" do
    it "adds a new circle in its place and keeps every other node" do
      expect(result.dig("set_change", "same_node")).to be(true)
      expect(result.dig("set_change", "keys")).to eq(
        ["chore:1", "chore:2", "chore:4", "trigger:3", "credit:7", "task:9", "task:8"],
      )
    end

    it "takes one out the same way" do
      expect(result.dig("set_change", "after_removal")).to eq(
        ["chore:1", "chore:2", "chore:4", "trigger:3", "credit:7", "task:8"],
      )
      expect(result.dig("set_change", "same_node_after_removal")).to be(true)
    end
  end
end
