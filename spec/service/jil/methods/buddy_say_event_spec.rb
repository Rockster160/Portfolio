require "rails_helper"

# Buddy.sayEvent — the same fixed message as Buddy.say, but addressed to
# whoever the EVENT belongs to rather than to whoever's task is running.
#
# The travel alerts are why: they're computed by Rocco's tasks (his car, his
# address book) and may be about an event on somebody else's calendar, where
# "leave by 5:30" is no use to the person not going.
RSpec.describe Jil::Methods::Buddy do
  let(:owner)   { User.me }
  let(:partner) { create(:user, phone: "5550000201") }
  let!(:owner_convo)   { owner.byte_conversations.create!(mode: :buddy, name: "Byte") }
  let!(:partner_convo) { partner.byte_conversations.create!(mode: :buddy, name: "Moss") }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(::AgendaTravelChainSyncWorker).to receive(:perform_async).and_return(nil)
    allow(::Jil).to receive(:trigger)
  end

  def event_on(agenda)
    agenda.agenda_items.create!(
      kind:     :event,
      name:     "Dinner",
      start_at: 1.day.from_now,
      end_at:   1.day.from_now + 1.hour,
      location: "Ruth's Chris",
    )
  end

  def say_event(item, message, as: owner)
    Jil::Executor.call(as, <<~JIL, {})
      told = Buddy.sayEvent(#{item.id}, "#{message}")::Numeric
    JIL
  end

  def bodies_for(convo)
    convo.byte_messages.reload.map(&:body)
  end

  it "validates as Jil" do
    code = <<~'JIL'
      eid = Numeric.new(4)::Numeric
      told = Buddy.sayEvent(eid, "Leave by 5:30 to make dinner")::Numeric
    JIL
    expect { Jil::Validator.validate!(code) }.not_to raise_error
  end

  describe "a personal calendar" do
    let(:agenda) { owner.agendas.create!(name: "Work") }

    it "tells the owner and returns the count" do
      ctx = say_event(event_on(agenda), "Leave by 5:30")

      expect(ctx.ctx[:vars][:told][:value]).to eq(1)
      expect(bodies_for(owner_convo)).to eq(["Leave by 5:30"])
    end

    # The rule the user asked for in as many words: personal calendars reach
    # only the relevant person, even when they're shared.
    it "still tells only the owner when it's shared with an editor" do
      agenda.agenda_shares.create!(user: partner, permission: :editor)
      say_event(event_on(agenda), "Leave by 5:30")

      expect(bodies_for(owner_convo)).to eq(["Leave by 5:30"])
      expect(bodies_for(partner_convo)).to be_empty
    end
  end

  describe "a joint calendar" do
    let(:agenda) { owner.agendas.create!(name: "Ours") }

    before { agenda.agenda_shares.create!(user: partner, permission: :owner) }

    it "tells everyone whose calendar it is" do
      ctx = say_event(event_on(agenda), "Leave by 5:30")

      expect(ctx.ctx[:vars][:told][:value]).to eq(2)
      expect(bodies_for(owner_convo)).to eq(["Leave by 5:30"])
      expect(bodies_for(partner_convo)).to eq(["Leave by 5:30"])
    end
  end

  # The reverse case: a calendar shared IN to the person whose task is
  # computing the drive. The alert is about her day, so it goes to her.
  describe "somebody else's calendar, shared in" do
    let(:agenda) { partner.agendas.create!(name: "Hers") }

    before { agenda.agenda_shares.create!(user: owner, permission: :viewer) }

    it "tells its owner, not the person running the task" do
      say_event(event_on(agenda), "Leave by 5:30")

      expect(bodies_for(partner_convo)).to eq(["Leave by 5:30"])
      expect(bodies_for(owner_convo)).to be_empty
    end
  end

  describe "nobody to tell" do
    let(:agenda) { owner.agendas.create!(name: "Work") }

    # Missing beats wrong: a stale trigger for a deleted event has no audience
    # to infer, so it reaches nobody and says so.
    it "returns 0 for an event that can't be resolved" do
      ctx = Jil::Executor.call(owner, <<~'JIL', {})
        told = Buddy.sayEvent(0, "Leave by 5:30")::Numeric
      JIL

      expect(ctx.ctx[:vars][:told][:value]).to eq(0)
      expect(ByteMessage.count).to eq(0)
    end

    it "returns 0 on a blank message" do
      ctx = say_event(event_on(agenda), "   ")

      expect(ctx.ctx[:vars][:told][:value]).to eq(0)
      expect(ByteMessage.count).to eq(0)
    end

    # No companion gets spun up by a notification — same gate as
    # AgendaNotifyOthersWorker.
    it "skips a co-owner who has never opened Buddy" do
      stranger = create(:user, phone: "5550000202")
      agenda.agenda_shares.create!(user: stranger, permission: :owner)
      ctx = say_event(event_on(agenda), "Leave by 5:30")

      expect(ctx.ctx[:vars][:told][:value]).to eq(1)
      expect(stranger.byte_conversations.count).to eq(0)
    end

    it "returns 0 for an event on a calendar the task can't see" do
      hidden = partner.agendas.create!(name: "Private")
      ctx = say_event(event_on(hidden), "Leave by 5:30")

      expect(ctx.ctx[:vars][:told][:value]).to eq(0)
      expect(ByteMessage.count).to eq(0)
    end
  end

  it "lands verbatim, with no model turn" do
    agenda = owner.agendas.create!(name: "Work")
    expect(BuddyDeliverWorker).not_to receive(:perform_async)

    say_event(event_on(agenda), "Leave by 5:30")

    message = owner_convo.byte_messages.last
    expect(message.direction).to eq("inbound")
    expect(message.metadata).to include("kind" => "buddy", "source" => "jil")
  end
end
