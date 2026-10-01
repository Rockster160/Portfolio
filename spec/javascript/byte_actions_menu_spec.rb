require "rails_helper"

# Rocco, 2026-09-09: "The actions bar of buttons is used very little for how
# much space it uses. Instead, let's collapse it into the top bar."
#
# It was five chips in a row under the pet — Quick, What now?, Stash, Check-in,
# Affirmation — each of the first four opening a popover that covered Buddy.
# Now it's one header button and one popover: a root list, and a panel per
# choice that has its own options, swapping in place.
#
# The part worth holding onto in a test is that "in place" is real. Four
# separate popovers each with their own open/close pair is what it was, and the
# way that fails is two of them on screen at once — which is exactly what the
# old stylesheet had a `display: none !important` rule to paper over.
RSpec.describe "Byte actions menu" do
  let(:result) { JsRunner.output("spec/javascript/byte_actions_menu_runner.js") }

  it "starts closed" do
    expect(result["closed_at_boot"]).to eq("open" => false, "panel" => nil, "expanded" => nil)
  end

  it "opens on the root list" do
    expect(result["opened"]).to eq("open" => true, "panel" => "root", "expanded" => "true")
  end

  describe "a choice that has its own options" do
    # The whole point of one popover instead of five. `showPanel` names the one
    # to show, so there is no arrangement of taps that leaves two up.
    it "replaces the list rather than opening beside it" do
      expect(result["into_suggest"]["panel"]).to eq("suggest")
      expect(result["into_suggest"]["root_hidden"]).to be(true)
      expect(result["into_suggest"]["open"]).to be(true)
    end

    it "goes back to the list" do
      expect(result["after_back"]["panel"]).to eq("root")
    end

    it "acts and closes when one of the options is picked" do
      expect(result["after_suggest"]["open"]).to be(false)
      expect(result["after_stash"]["open"]).to be(false)
      expect(result["after_mood"]["open"]).to be(false)
    end
  end

  it "acts and closes on a choice with no options of its own" do
    expect(result["after_affirmation"]["open"]).to be(false)
  end

  it "sends what was picked, not just which row was tapped" do
    expect(result["requests"]).to include(
      a_hash_including(
        "url"  => "/buddy/quick_action",
        "body" => { "kind" => "checkin", "mood" => "low", "conversation_id" => 42 },
      ),
      a_hash_including(
        "url"  => "/buddy/quick_action",
        "body" => { "kind" => "stash", "category" => "work", "conversation_id" => 42 },
      ),
    )
  end

  it "arms the composer for the stashed bucket" do
    expect(result["armed"]).to eq(["work"])
  end

  # Reopening onto whichever panel the last tap left showing hides the rest of
  # the list, and the only way out is a back row nobody expected to need.
  it "comes back to the root list on the next open" do
    expect(result["reopened"]["panel"]).to eq("root")
  end

  describe "closing" do
    it "closes on a tap outside" do
      expect(result["after_outside"]["open"]).to be(false)
      expect(result["after_outside"]["expanded"]).to eq("false")
    end

    it "stays open for a tap inside it" do
      expect(result["inside_stays_open"]).to eq(
        "open" => true, "panel" => "stash", "expanded" => "true",
      )
    end
  end

  # A claude/bash thread has nothing behind the button, and the menu it opens
  # is the pet's.
  describe "on a conversation that isn't Buddy's" do
    it "takes the button away and shuts the menu" do
      expect(result["non_buddy"]["toggle_hidden"]).to be(true)
      expect(result["non_buddy"]["open"]).to be(false)
    end

    it "gives it back on the way in" do
      expect(result["back_to_buddy"]["toggle_hidden"]).to be(false)
    end
  end

  # Rocco, 2026-10-01: "Other quick actions should be immediately available in
  # the list that shows up when clicking the quick action button. Hiding them
  # behind several clicks is not quick."
  #
  # They were behind a "Quick" row of their own, which made the one-tap things
  # two taps. Now they ARE the top of the root list, rendered by the server and
  # re-read on each open.
  describe "the saved routines" do
    # Server-rendered, so they are there on the first frame. Fetching them on
    # open was fine while they had a panel to themselves; at the top of the
    # root list a loading line pushes every row under it down on every open.
    it "is already in the list before any request answers" do
      expect(result["rows_at_boot"]).to eq([{ "id" => "5", "label" => "Wind down" }])
    end

    it "sits in the root list rather than a panel of its own" do
      expect(result["after_open"]["panel"]).to eq("root")
    end

    # The re-read is what the fetch is still for: one saved since this page
    # loaded shows up without a reload.
    it "picks up one saved since the page loaded" do
      expect(result["after_open"]["rows"]).to eq(
        [{ "id" => "5", "label" => "Wind down" }, { "id" => "9", "label" => "Cup water" }],
      )
    end

    it "runs the one tapped and closes" do
      expect(result["requests"]).to include(
        a_hash_including("url" => "/buddy/routines/5/run", "method" => "POST"),
      )
      expect(result["after_routine"]["open"]).to be(false)
    end

    # It used to write "Couldn't load those." in, which was right when that was
    # the whole content of the panel. Here the rows are already correct, and a
    # request nobody asked for is no reason to take them away.
    it "leaves the rows standing when the re-read fails" do
      expect(result["after_failed_refresh"]["rows"]).to eq(
        [{ "id" => "5", "label" => "Wind down" }, { "id" => "9", "label" => "Cup water" }],
      )
    end

    # The count is the second half: a redraw has to clear the rows it drew last
    # time, or the list only grows and an emptied one still shows the routine
    # that used to be in it, under a sentence saying there are none.
    it "says what would produce one when there are none" do
      expect(result["empty"]["text"]).to eq("No routines saved yet — ask to save one.")
      expect(result["empty"]["rows"]).to eq(0)
    end
  end
end
