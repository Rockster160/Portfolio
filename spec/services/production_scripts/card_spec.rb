require "rails_helper"

RSpec.describe ProductionScripts::Card do
  let(:user) { User.me }
  let(:thread) { user.byte_conversations.create!(name: :Buddy, mode: :buddy) }
  let(:build) {
    FeatureBuild.create!(
      user:              user,
      byte_conversation: thread,
      title:             "Workout pings",
      request:           "ping",
      status:            :running,
      rc_url:            "https://claude.ai/code/session_abc",
      pr_url:            "https://github.com/x/y/pull/7",
      pr_number:         7,
    )
  }
  let(:code) {
    <<~RUBY
      task = JilTask.find(49)
      task.update!(code: <<~'JIL')
        done = Global.trigger("workout", {})::Boolean
      JIL
      puts "WROTE task 49"
    RUBY
  }
  let(:script) {
    ProductionScripts.create!(
      user: user, feature_build: build, title: "Lowes Airsports key", code: code, commit_sha: "abc1234", edited_by: :mini,
    )
  }

  before { allow(Buddy::CompanionDelivery).to receive(:notify) }

  it "posts into the build's thread, and draws from the script as it is now" do
    card = described_class.post!(script)

    expect(card.byte_conversation).to eq(thread)
    wire = card.as_wire[:script]
    expect(wire).to include(
      id:          script.id,
      title:       "Lowes Airsports key",
      status:      "pending",
      approvable:  true,
      skippable:   true,
      pr_url:      "https://github.com/x/y/pull/7",
      session_url: "https://claude.ai/code/session_abc",
      superseded:  false,
    )
    expect(wire[:url]).to end_with("/system/production_scripts/#{script.id}")
    expect(wire[:html]).to include("<span class=\"rh-const\">JilTask</span>", "ps-heredoc ps-jil")

    script.update!(status: :skipped)
    expect(card.reload.as_wire[:script]).to include(status: "skipped", approvable: false, skippable: false)
  end

  it "goes to the primary thread when the script came from no build" do
    script.update!(feature_build: nil)
    allow(ByteConversation).to receive(:for_self_initiated).with(user).and_return(thread)

    expect(described_class.post!(script).byte_conversation).to eq(thread)
  end

  it "leaves an older card pointing at the newer one once the script is sent again" do
    first = described_class.post!(script)
    second = described_class.post!(script, updated: true)

    expect(first.reload.as_wire[:script]).to include(superseded: true)
    expect(second.as_wire[:script]).to include(superseded: false, step: "Changed, so it needs approving again")
  end

  it "says only what it was when the script is gone" do
    card = described_class.post!(script)
    script.destroy!

    expect(card.reload.as_wire[:script]).to be_nil
  end
end
