require "rails_helper"

# A ByteAction attached to a message only becomes visible if the client knows to
# mount something under it, and that list is three hardcoded `tool_name ===`
# checks in the renderer. There is nothing linking the two ends: attach a new
# action server-side and the metadata rides down, the message renders, and the
# buttons simply aren't there.
#
# That shipped. `buddy_timer_cycle` posted its card, `as_wire` carried the
# request id and the button, and it drew as a plain sentence — "Demo: 60s on,
# 30s off. Tap to start 💛" with nothing to tap.
RSpec.describe "message action mounts" do
  let(:renderer) { Rails.root.join("app/javascript/src/pages/byte/index.js").read }

  # Every tool_name the server attaches to a byte_message as an action. Read off
  # the constants where there are constants, so a rename can't leave this
  # passing against a name nothing uses any more.
  def attached
    [
      "buddy_proposals",
      "buddy_relay_answer",
      Buddy::ReminderList::TOOL_NAME,
      Buddy::FormAction::TOOL_NAME,
      Buddy::TimerCycle::TOOL_NAME,
    ]
  end

  it "mounts something for every action the server attaches" do
    missing = attached.reject { |name| renderer.include?(%(tool_name === "#{name}")) }

    expect(missing).to be_empty,
      "the client mounts nothing for #{missing.inspect}, so these render as a bare message " \
      "with their buttons dropped on the floor"
  end

  # The one that got missed, named outright — the general check above passes the
  # day someone deletes this branch and the constant with it.
  it "mounts the work/break button" do
    expect(renderer).to include(%(tool_name === "buddy_timer_cycle"))
    expect(renderer).to include("renderCycleButton")
  end

  it "imports each renderer it mounts" do
    %w[renderMultiSelect renderForm renderCycleButton].each do |fn|
      expect(renderer).to match(/import \{ #{fn} \} from/), "#{fn} is mounted but never imported"
    end
  end
end
