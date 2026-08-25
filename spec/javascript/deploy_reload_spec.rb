require "rails_helper"

# "Reload after deploy" had never once worked, and the chain behind it was fine:
# on the last deploy, task 34 (`startup`) ran at 18:37:40, task 106 read the
# request flag and fired task 334 at 18:37:43. Three seconds, no errors.
#
# Three seconds after the new Rails boots is the problem. The reload went out as
# `Global.broadcast_websocket("Jarvis", {reload: true})` — fire and forget, at a
# socket a server restart had just killed, which ActionCable will not reopen
# until its 12s stale threshold elapses. Nobody was listening. And task 106
# clears the request flag before firing, so there was nothing left to retry: one
# missed frame and the request was gone.
#
# Being told only works if you are there to hear it. So the dashboard ASKS, on
# the socket it has just re-established, and the answer waits in
# `dashboard_reload.sha` until something claims it.
#
# That inverts the risk. A push that gets lost does nothing; a pull that keeps
# being answered reloads forever, and a wall display stuck in a reload loop is
# worse than one showing week-old code. So the guards below are the actual
# feature, and they are written to fail CLOSED — every unknown is a refusal.
RSpec.describe "Dashboard deploy reload" do
  let(:result) { JsRunner.output("spec/javascript/deploy_reload_runner.js") }

  # Nothing else in this file matters if the question never gets asked. This is
  # the whole fix: the moment the socket is back is the moment we ask.
  # The build it is running rides along with the question. That is what lets the
  # answer be computed from facts that are already true when it is asked, rather
  # than from a deploy event it has to be present for.
  it "asks on connect, saying what it is running" do
    expect(result["connect_asks"]).to eq([["resync", "dashboard-reload", "old"]])
  end

  describe "when the page really is stale" do
    it "reloads" do
      expect(result["stale_reloads"]).to eq(1)
    end

    it "writes down which build it reloaded for" do
      expect(result["stale_remembered"]).to eq("new")
    end
  end

  describe "refusing to loop" do
    # A re-broadcast, a second reconnect, a server that never cleared the flag.
    it "reloads once however many times it is told to" do
      expect(result["repeat_reloads"]).to eq(1)
    end

    # The one that would actually spin: it comes back up STILL on the old sha —
    # a rolling deploy served it from a box that hadn't restarted yet — and is
    # told again. The sha check can't catch this one; only the record of having
    # already done it can, which is why that record is local and survives the
    # reload it guards.
    it "does not reload again when the reload did not take" do
      expect(result["still_stale_after_reload_reloads"]).to eq(1)
    end

    # The guard is per target, not a one-shot latch — otherwise the first deploy
    # would disarm this permanently for the life of the tab.
    it "still reloads for a genuinely newer build" do
      expect(result["second_deploy_reloads"]).to eq(2)
    end
  end

  describe "refusing on anything it cannot verify" do
    it "does not reload a page already running the target build" do
      expect(result["already_current_reloads"]).to eq(0)
    end

    # No `DASHBOARD_SHA` means the stale check is gone, and the loop guard alone
    # would let a server repeating itself reload every fresh tab. An older
    # dashboard, open from before this shipped, lands here — it sits still.
    it "does not reload a page that cannot say what it is running" do
      expect(result["unknown_build_reloads"]).to eq(0)
    end

    # Without storage there is no way to promise not to do it twice, so it
    # declines rather than proceeding unguarded.
    it "does not reload when it cannot record having done so" do
      expect(result["no_storage_reloads"]).to eq(0)
    end

    it "ignores a broadcast that names no target" do
      expect(result["empty_payload_reloads"]).to eq(0)
    end
  end

  describe "the decision, stated" do
    it "gives the reason it refused" do
      expect(result["decisions"]).to eq(
        "stale"                   => "reload",
        "no_target"               => "no-target",
        "blank_target"            => "no-target",
        "unknown_build"           => "unknown-build",
        "already_current"         => "already-current",
        "already_reloaded"        => "already-reloaded",
        "new_target_after_reload" => "reload",
      )
    end
  end
end
