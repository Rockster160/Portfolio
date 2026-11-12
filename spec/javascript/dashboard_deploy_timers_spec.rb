require "rails_helper"

# The deploy monitor only ever re-sends the latest deploy, so one whose result
# was missed while the dashboard reloaded never hears it again. A later deploy
# succeeding has shipped that code too, and settles it.
RSpec.describe "dashboard deploy timers (JS-side)" do
  let(:result) {
    JsRunner.output("spec/javascript/dashboard_deploy_timers_runner.js", symbolize: true)
  }

  it "leaves an earlier deploy running while a newer one is still deploying" do
    expect(result.dig(:newer_running, :stuck)).to include(completed: false)
  end

  it "settles an earlier deploy that never reported once a newer one succeeds" do
    expect(result.dig(:newer_succeeded, :stuck)).to include(
      completed:   true,
      errored:     false,
      note:        "superseded",
      finished_at: result.dig(:saved_end, :stuck),
    )
  end

  it "leaves deploys that already finished as they were" do
    expect(result.dig(:newer_succeeded, :earlier)).to eq(result.dig(:newer_running, :earlier))
  end

  it "finishes the newer deploy with its own run time" do
    expect(result.dig(:newer_succeeded, :newer)).to include(completed: true, note: "2m45s")
  end
end
