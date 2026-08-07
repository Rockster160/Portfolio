require "rails_helper"

# A watch that starts a COUNTDOWN instead of saying something.
#
# Prod Aug 7: "Set a 1 second timer every time something comes into the Claude
# list in the Ocs Backend section." got a reminder watch, then "No. I said set a
# TIMER. Not a reminder." got "A timer only runs from now, so this needs a
# watch, not a countdown." Both halves were true of the tools that existed and
# neither was what was asked for: a message is something you have to be looking
# at, and a timer makes a noise in the room, which is the entire reason to ask
# for a one-second one.
RSpec.describe "Buddy watch timers" do
  let(:user) { create(:user) }
  let!(:list_task) {
    Task.create!(
      user: user, name: "Claude List Log", listener: "item:action:added",
      code: "", enabled: true, buddy_enabled: true
    )
  }
  let!(:list) { user.lists.create!(name: "Claude").tap { |l| user.user_lists.create!(list: l) } }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    Rails.cache.delete("jil:wired_scopes:#{user.id}")
  end

  def run(payload)
    markers = [{ tool_name: :remind_when, payload: payload, span: [0, 0] }]
    Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
  end

  def claude_list(**extra)
    {
      text:        "Claude list got something",
      trigger:     "custom",
      listener:    "item:action:added item:list:name:/^Claude$/",
      when_phrase: "when something is added to the Claude list",
      repeat:      true,
      **extra,
    }
  end

  describe "setting one" do
    it "makes a timer watch carrying the countdown length" do
      expect { run(claude_list(timer: 1)) }.to change(BuddyWatch, :count).by(1)

      watch = BuddyWatch.last
      expect(watch.kind).to eq("timer")
      expect(watch).to be_timer
      expect(watch.timer_seconds).to eq(1)
    end

    it "says it will start a timer, not that it will remind them" do
      run(claude_list(timer: 1))

      chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
      expect(chip.body).to include("timer")
      expect(chip.body).not_to include("remind you")
    end

    it "still makes an ordinary reminder watch when no timer is named" do
      run(claude_list)

      expect(BuddyWatch.last.kind).to eq("prompt")
      expect(BuddyWatch.last.timer_seconds).to be_zero
    end

    it "does not both tell someone else and set a timer" do
      create(:user, username: "chelsea")

      run(claude_list(timer: 1, notify: "chelsea"))

      expect(BuddyWatch.count).to eq(0)
    end

    it "caps an absurd countdown at what the timer stack would take anyway" do
      run(claude_list(timer: 9_999_999))

      expect(BuddyWatch.last.timer_seconds).to eq(Buddy::Timers::MAX_SECONDS)
    end
  end

  describe "when it fires" do
    let!(:watch) {
      run(claude_list(timer: 1))
      BuddyWatch.last
    }

    it "starts a countdown rather than posting a message" do
      expect {
        Buddy::WatchMatcher.fire!(watch)
      }.to change { user.timers.count }.by(1)

      timer = user.timers.order(:id).last
      expect(timer.duration_ms).to eq(1_000)
    end

    it "names the countdown with what the watch was about" do
      Buddy::WatchMatcher.fire!(watch)

      expect(user.timers.order(:id).last.name).to eq("Claude list got something")
    end

    it "keeps firing while the watch repeats" do
      Buddy::WatchMatcher.fire!(watch)
      watch.reload.update!(metadata: watch.metadata.except("last_signature"))

      expect { Buddy::WatchMatcher.fire!(watch) }.to change { user.timers.count }.by(1)
    end

    it "leaves the thread alone — the alarm is the message" do
      said = -> { convo.byte_messages.where("metadata->>'source' = 'watch'").count }

      expect { Buddy::WatchMatcher.fire!(watch) }.not_to change(said, :call)
    end
  end

  # A timer watch and a reminder watch read identically in context otherwise,
  # which is the exact distinction that went wrong in the first place.
  it "says what it does when Buddy looks at what it's watching" do
    run(claude_list(timer: 1))

    listed = Buddy::Context.send(:active_watches, convo)

    expect(listed.first[:does]).to eq("starts a 1 sec timer")
  end
end
