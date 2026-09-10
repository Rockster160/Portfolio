require "rails_helper"

# Byte replacing its own shell once an update has landed and nobody is there to
# press the button. The whole risk is the other side of it: a reload throws away
# scroll position, a half-typed message and anything open over the thread, so
# the conditions have to be narrow enough that a person never watches the page
# go out from under them.
RSpec.describe "Byte idle reload" do
  let(:result) { JsRunner.output("spec/javascript/byte_idle_reload_runner.js") }
  let(:decisions) { result["decisions"] }

  describe "the rule" do
    it "reloads an unattended tab that has gone quiet" do
      expect(decisions["unattended"]).to eq("reload")
    end

    # The condition that separates "idle" from "unattended". Five minutes of no
    # input with the app in front of them is what reading a long reply looks
    # like, and that is the one case this must never interrupt.
    it "leaves a page alone while it still has focus, however long they sit still" do
      expect(decisions["reading"]).to eq("watching")
    end

    it "counts another window on top of it as unattended, even while visible" do
      expect(decisions["window_behind"]).to eq("reload")
    end

    it "waits five minutes from the last thing they did" do
      expect(result["idle_ms"]).to eq(5 * 60 * 1000)
      expect(decisions["just_touched"]).to eq("recently-used")
      expect(decisions["a_hair_short"]).to eq("recently-used")
      expect(decisions["at_the_boundary"]).to eq("reload")
    end

    # The reload empties every cache before it navigates, and a navigation with
    # no network never lands — it doesn't fail, it simply doesn't happen. What
    # would be left is worse than the stale shell it was replacing.
    it "declines offline rather than emptying the caches into a dead navigation" do
      expect(decisions["offline"]).to eq("offline")
    end

    it "declines whenever the app isn't settled" do
      expect(decisions["not_quiet"]).to eq("unsettled")
    end

    it "answers with the strongest reason first" do
      expect(decisions["used_and_offline"]).to eq("recently-used")
    end
  end

  describe "the watch" do
    it "does nothing until it's armed, and nothing while the page is fresh" do
      expect(result["armed_at_rest"]).to be(false)
      expect(result["armed_after_arm"]).to be(true)
      expect(result["reloads_while_fresh"]).to eq(0)
    end

    it "reloads once and disarms itself" do
      expect(result["reloads_when_unattended"]).to eq(1)
      expect(result["armed_after_reload"]).to be(false)
      expect(result["reloads_after_a_second_tick"]).to eq(1)
    end

    it "starts the five minutes over on anything they do with their hands" do
      expect(result["reloads_after_a_touch"]).to eq(0)
      expect(result["decision_after_a_touch"]).to eq("recently-used")
      expect(result["reloads_once_the_touch_ages_out"]).to eq(1)
    end

    # No pointer moves to do it, so without this the moment of picking the phone
    # up is also the moment the page decides nobody is there.
    it "treats coming back to the app as using it" do
      expect(result["reloads_after_returning"]).to eq(0)
    end

    it "holds off while something is open over the thread" do
      expect(result["reloads_while_unsettled"]).to eq(0)
      expect(result["decision_while_unsettled"]).to eq("unsettled")
    end
  end
end
