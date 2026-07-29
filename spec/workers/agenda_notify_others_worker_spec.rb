require "rails_helper"

RSpec.describe AgendaNotifyOthersWorker do
  let(:actor)     { create(:user) }
  let(:partner)   { create(:user) }
  let(:viewer)    { create(:user) }
  let(:no_buddy)  { create(:user) }
  let(:agenda)    { create(:agenda, user: actor, name: "Ours 💕") }
  let(:item)      { create(:agenda_item, agenda: agenda, kind: :task, name: "Groceries") }

  before do
    # partner (editor) + viewer both share the agenda and use Buddy;
    # no_buddy shares it but has never opened a Buddy conversation.
    AgendaShare.create!(agenda: agenda, user: partner, permission: :editor)
    AgendaShare.create!(agenda: agenda, user: viewer, permission: :viewer)
    AgendaShare.create!(agenda: agenda, user: no_buddy, permission: :editor)
    [actor, partner, viewer].each { |u| ByteConversation.create!(user: u, mode: :buddy, name: "Buddy") }

    allow(Buddy::CompanionRelay).to receive(:conversation_for) { |u| u.byte_conversations.first }
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
  end

  it "briefs every OTHER Buddy user on the agenda, once each" do
    described_class.new.perform("AgendaItem", item.id, actor.id, "created")

    expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt).with(hash_including(user: partner)).once
    expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt).with(hash_including(user: viewer)).once
  end

  it "never briefs the actor" do
    described_class.new.perform("AgendaItem", item.id, actor.id, "created")
    expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt).with(hash_including(user: actor))
  end

  it "skips agenda members who don't use Buddy" do
    described_class.new.perform("AgendaItem", item.id, actor.id, "created")
    expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt).with(hash_including(user: no_buddy))
  end

  it "passes the created/updated action through to the seed" do
    described_class.new.perform("AgendaItem", item.id, actor.id, "updated")
    expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt).with(
      hash_including(seed: a_string_including("just changed")),
    ).at_least(:once)
  end

  it "no-ops when the source no longer exists" do
    described_class.new.perform("AgendaItem", item.id + 999_999, actor.id, "created")
    expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
  end

  it "handles an AgendaSchedule source" do
    schedule = create(:agenda_schedule, agenda: agenda, kind: :event, name: "Standup", duration_minutes: 30)
    described_class.new.perform("AgendaSchedule", schedule.id, actor.id, "created")

    expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt).with(hash_including(user: partner)).once
  end
end
