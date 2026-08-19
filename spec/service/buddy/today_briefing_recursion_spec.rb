require "rails_helper"

# A Today briefing cannot send a Today briefing.
#
# Dev, 19 Aug: 28 briefings in under two minutes, one every four seconds, each
# reply announcing that the briefing had gone out rather than being it — "Done!
# Your Today briefing is up ✨". The seed arrives, the turn answering it is
# offered `today_briefing`, calling that posts another seed, and that seed's
# turn is offered the same tool.
#
# Two prose guards were already in place and both lost: the tool's own
# description says "almost nothing said to you is a reason to call this", and
# the seed could hardly be more explicit about wanting the briefing itself. A
# turn that IS the briefing can never have a reason to send one, so it stops
# being reachable rather than being advised against.
RSpec.describe "Buddy Today briefing recursion" do
  let(:user)   { create(:user) }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  around { |ex| Sidekiq::Testing.fake! { ex.run } }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    convo.update_columns(buddy_theme: "byte")
  }

  # Tool names come back as symbols.
  def names_in(client)
    client.calls.first.tools.filter_map { |schema| (schema[:name] || schema["name"])&.to_sym }
  end

  # The seed the real briefing sends, marker and all.
  def seed!
    convo.byte_messages.create!(
      user:      user,
      direction: :outbound,
      state:     :sent,
      body:      Buddy::TodayBriefing.seed(user),
      metadata:  {
        "kind" => "buddy_trigger", "hidden" => true,
        "source" => "today_scheduled", "buddy_action" => "today",
      },
    )
  end

  def run_briefing!(seed = seed!)
    client = FakeBuddyClient.new([{ text: "Morning! Two things today." }])
    Buddy::GPT::Turn.run!(seed, client: client)
    client
  end

  it "is not offered the tool that would send another one" do
    expect(names_in(run_briefing!)).not_to include(:today_briefing)
  end

  it "still gets everything else it needs to write the thing" do
    names = names_in(run_briefing!)

    expect(names).to include(:get_context, :complete_chore, :log_event)
  end

  # The whole failure was a SECOND seed appearing behind the first.
  it "produces no further briefing seed of its own" do
    seed = seed!

    expect { run_briefing!(seed) }
      .not_to change { convo.byte_messages.where("metadata->>'buddy_action' = 'today'").count }
  end

  it "leaves the tool available on an ordinary turn, so it can still be asked for" do
    inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "send me my Today")
    client  = FakeBuddyClient.new([{ text: "Sure." }])
    Buddy::GPT::Turn.run!(inbound, client: client)

    expect(names_in(client)).to include(:today_briefing)
  end

  describe "Buddy::Tools.function_schemas" do
    it "withholds that one and nothing else" do
      offered  = Buddy::Tools.function_schemas(user: user).filter_map { |s| s[:name]&.to_sym }
      withheld = Buddy::Tools.function_schemas(user: user, briefing: true).filter_map { |s| s[:name]&.to_sym }

      expect(offered).to include(:today_briefing)
      expect(withheld).not_to include(:today_briefing)
      expect(offered - withheld).to eq([:today_briefing])
    end
  end
end
