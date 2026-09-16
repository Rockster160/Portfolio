require "rails_helper"

# The chips in the top-right of the Buddy hero: what Byte is doing while nobody
# is watching it. Everything here is reported by whoever is doing the work, so
# this covers only what the strip does with what it is told.
RSpec.describe "Buddy background process strip" do
  let(:result) { JsRunner.output("spec/javascript/byte_process_strip_runner.js") }

  describe "a running process" do
    it "reads as its name, its place in the batch, and the step it is on" do
      expect(result["running"].first["text"])
        .to eq(["⚙", "Preparing", "3/13", "Fieldwire - writing the letter"])
    end

    # A total with no current is nothing anybody can read, so the count waits
    # for its other half rather than inventing one.
    it "shows a count with no total, and no count with neither" do
      expect(result["count_without_total"]).to include("3")
      expect(result["no_count"]).to eq(["⚙", "Preparing", "Fieldwire - writing the letter"])
    end

    it "leaves the corner of the hero empty when nothing is running" do
      expect(result["empty"]).to eq({ "shown" => 0, "hidden" => true })
    end
  end

  describe "when it goes quiet" do
    # The count it is showing is frozen. A chip that goes on looking live is
    # the one thing worse than no chip at all.
    it "says stalled rather than going on claiming progress" do
      chip = result["stale"].first

      expect(chip["stale"]).to eq("true")
      expect(chip["text"].last).to start_with("Stalled — ")
    end

    # Waiting is stalled on purpose, and it already says what it is waiting for.
    it "leaves work that is waiting on a person alone" do
      chip = result["waiting"].first

      expect(chip["stale"]).to be_nil
      expect(chip["text"]).to eq(["❓", "Preparing", "3/13", "8 questions waiting on you"])
    end
  end

  # The strip overlays Buddy, and the whole point of him is that he is visible.
  describe "how much of the hero it takes" do
    it "shows three and says how many it left out" do
      expect(result["capped"]).to eq({ "chips" => 3, "more" => ["+2 more"] })
    end

    # Three of eight shown, with nothing said about it, would read as three.
    it "says nothing when nothing was left out" do
      expect(result["uncapped_more"]).to eq(0)
    end

    # A third row costs about as much height as the other two together.
    it "spends the link row only where there is something to choose or act on" do
      expect(result["one_link_running"]["links"]).to eq([])
      expect(result["one_link_running"]["has_url"]).to eq("true")
      expect(result["one_link_waiting"]["links"].length).to eq(1)
    end
  end

  describe "the links" do
    # Real anchors, so a long-press offers to copy one and a middle-click opens
    # a tab. None of that is worth reimplementing on a tap handler.
    it "are anchors that open in their own tab" do
      expect(result["links"]).to eq([
        { "label" => "Posting", "href" => "https://boards.greenhouse.io/x/jobs/1", "target" => "_blank" },
        { "label" => "Line", "href" => "http://localhost:8790/line", "target" => "_blank" },
      ])
    end

    # Otherwise reaching for the job would be asking for the chip to be cleared.
    it "do not start the chip's swipe" do
      expect(result["pill_stops_the_swipe"]).to eq(1)
    end
  end

  describe "a tap on the chip itself" do
    it "opens the only link there is" do
      expect(result["one_link_has_url"]).to eq("true")
      expect(result["tap_opened"]).to eq(["http://localhost:8790/line"])
    end

    # With several there is no single right answer, and guessing one is how a
    # tap meant for the queue opens a job posting instead.
    it "does nothing when there is more than one" do
      expect(result["two_links_has_url"]).to be_nil
      expect(result["tap_with_two_links"]).to eq([])
    end

    it "does nothing when there are none" do
      expect(result["tap_without_links"]).to eq([])
    end
  end

  # Same rule the timer chips had to learn (prod timer 94): a chip that leaves
  # on the gesture is indistinguishable from one that leaves on a failed
  # request, and the failure means work nobody can see still running.
  describe "a swipe" do
    it "asks the server rather than deciding" do
      expect(result["ok_requests"]).to eq(["DELETE /api/v1/background_processes/jobhunt%3Aline"])
      expect(result["after_ok_swipe"]).to eq([])
    end

    it "keeps the chip on screen while the request is out, and takes no more gestures" do
      chip = result["in_flight"].first

      expect(chip["pending"]).to eq("clear")
      expect(chip["wired"]).to be(false)
      expect(result["second_swipe_requests"]).to eq([])
    end

    it "puts it back with a flash when the request never landed" do
      expect(result["after_failed_swipe"].first["pending"]).to eq("clear-failed")
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
