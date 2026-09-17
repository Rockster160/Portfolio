require "rails_helper"

# The chips in the top-right of the Buddy hero: what Byte is doing while nobody
# is watching it. Everything here is reported by whoever is doing the work, so
# this covers only what the strip does with what it is told.
RSpec.describe "Buddy background process strip" do
  let(:result) { JsRunner.output("spec/javascript/byte_process_strip_runner.js") }

  # It sits OVER Buddy, and the whole point of him is that he is visible. What
  # it spends its height on is the two things a person can act on: where the
  # run has got to, and where to go.
  describe "a chip" do
    it "says what it is and how far along, on one line" do
      chip = result["running"].first

      expect(chip["text"]).to eq(["Preparing", "3/13"])
    end

    it "is one row when it goes nowhere, and two when it does" do
      expect(result["no_links_rows"]).to eq(1)
      expect(result["running"].first["rows"]).to eq(2)
    end

    # Waiting on him, four links, a long step and a count - the most a chip is
    # ever asked to carry, and it still does not grow a third row.
    it "never grows past two rows" do
      expect(result["busiest"]["rows"]).to eq(2)
      expect(result["busiest"]["text"]).to eq(["Preparing", "3/13"])
    end

    # A total with no current is nothing anybody can read, so the count waits
    # for its other half rather than inventing one.
    it "shows a count with no total, and no count with neither" do
      expect(result["count_without_total"]).to include("3")
      expect(result["no_count"]).to eq(["Preparing"])
    end

    it "leaves the corner of the hero empty when nothing is running" do
      expect(result["empty"]).to eq({ "shown" => 0, "hidden" => true })
    end

    it "shows three and says how many it left out" do
      expect(result["capped"]).to eq({ "chips" => 3, "more" => ["+2 more"] })
    end

    # Three of eight shown, with nothing said about it, would read as three.
    it "says nothing when nothing was left out" do
      expect(result["uncapped_more"]).to eq(0)
    end
  end

  # The step it is on costs nothing as a title and a whole row anywhere else.
  describe "the step it is on" do
    it "rides along as the chip's title" do
      expect(result["running"].first["title"]).to eq("Fieldwire - writing the letter")
    end

    # A frozen count reads as work still going on, and the chip being dimmed is
    # the only other thing saying otherwise.
    it "says stalled first once nothing has been heard for a while" do
      chip = result["stale"].first

      expect(chip["stale"]).to eq("true")
      expect(chip["title"]).to start_with("Stalled — ")
    end

    # Waiting is stalled on purpose. It is not the same thing as having died.
    it "leaves work that is waiting on a person alone" do
      expect(result["waiting"].first["stale"]).to be_nil
    end
  end

  # A destination nobody can see is not a destination: these were read as
  # decoration on the bottom of a chip for a day, and "Posting" - the job
  # posting - was taken for a status. One word each, and the arrow that says
  # they go somewhere is CSS, so what is asserted here is what is read.
  describe "the links" do
    it "are drawn, as anchors that open in their own tab" do
      expect(result["links"]).to eq([
        { "label" => "Listing", "href" => "https://boards.greenhouse.io/x/jobs/1",
          "target" => "_blank" },
        { "label" => "Line", "href" => "http://localhost:8790/line", "target" => "_blank" },
      ])
    end

    # Otherwise reaching for the posting would open the chip's own link beside
    # the one that was actually pressed.
    it "are the tap, when the tap landed on one" do
      expect(result["tap_on_pill_opened"]).to eq([])
    end
  end

  describe "a tap on the chip itself" do
    # A bigger target for the common case of there being one link anyway.
    it "opens the first of them" do
      expect(result["has_url"]).to eq("true")
      expect(result["tap_opened"]).to eq(["https://boards.greenhouse.io/x/jobs/1"])
    end

    it "does nothing when the chip goes nowhere" do
      expect(result["no_url"]).to be_nil
      expect(result["tap_without_links"]).to eq([])
    end
  end

  # It was a swipe until 17 Sep and it never worked: the gesture needs the
  # pointer captured, and when the capture didn't take, `pointerup` went to
  # whatever was under the finger by then. The chip stayed where it had been
  # dragged - frequently off the edge of the strip - nothing was ever sent, and
  # it was still there on the next device to look. Rocco: "the swipe away
  # feature has just been bad from the start".
  describe "the × on a chip" do
    it "is on every chip, and says which one it closes" do
      expect(result["running"].first["closes"]).to be(true)
      expect(result["close_label"]).to eq("×")
      expect(result["close_aria"]).to eq("Dismiss Preparing")
    end

    # Same rule the timer chips had to learn (prod timer 94): a chip that leaves
    # on the tap is indistinguishable from one that leaves on a failed request,
    # and the failure means work nobody can see still running.
    it "asks the server rather than deciding" do
      expect(result["ok_requests"]).to eq(["DELETE /api/v1/background_processes/jobhunt%3Aline"])
      expect(result["after_ok_dismiss"]).to eq([])
    end

    # The × sits inside a chip whose body opens a tab.
    it "does not also open the chip's link" do
      expect(result["dismiss_opened"]).to eq([])
    end

    it "keeps the chip on screen while the request is out, and comes off it" do
      chip = result["in_flight"].first

      expect(chip["pending"]).to eq("clear")
      expect(chip["closes"]).to be(false)
      expect(result["second_dismiss"]).to be(false)
      expect(result["second_dismiss_requests"]).to eq([])
    end

    it "puts it back with a flash when the request never landed" do
      expect(result["after_failed_dismiss"].first["pending"]).to eq("clear-failed")
      expect(result["after_flash_clears"].first["pending"]).to be_nil
      expect(result["after_flash_clears"].first["key"]).to eq("jobhunt:line")
    end
  end

  # Clearing says "stop showing me this", not "stop doing that". The work is
  # still going, and it has to have somewhere to report to - otherwise a swipe
  # halfway through a twenty-minute run silences the rest of it.
  describe "after it has been cleared" do
    it "comes back on the next report" do
      expect(result["after_cleared_broadcast"]).to eq([])
      expect(result["after_report_following_clear"].first["text"]).to include("4/13")
    end
  end
end
