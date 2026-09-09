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

  # Reopening onto whichever panel the last tap left showing hides the other
  # four, and the only way out is a back row nobody expected to need.
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

  # The only panel whose contents come from the server, so it's the only one
  # that can be shown before it has anything in it.
  describe "the saved routines" do
    it "fills from the server" do
      expect(result["quick_loaded"]["panel"]).to eq("quick")
      expect(result["quick_loaded"]["rows"]).to eq([{ "id" => "5", "label" => "Wind down" }])
    end

    it "runs the one tapped and closes" do
      expect(result["requests"]).to include(
        a_hash_including("url" => "/buddy/routines/5/run", "method" => "POST"),
      )
      expect(result["after_routine"]["open"]).to be(false)
    end

    # The count is the second half: a refill has to clear the rows it drew last
    # time, or the panel only grows and an emptied list still shows the routine
    # that used to be in it, under a sentence saying there are none.
    it "says what would produce one when there are none" do
      expect(result["quick_empty"]["text"]).to eq("No routines saved yet — ask to save one.")
      expect(result["quick_empty"]["rows"]).to eq(0)
    end

    it "goes back to the list" do
      expect(result["quick_back"]["panel"]).to eq("root")
    end
  end
end
