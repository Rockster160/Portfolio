require "rails_helper"

# Cross-user watches: "whenever something's added to our Agenda, let Rocco
# know". The watch is owned by whoever the trigger fires for (an agenda's
# owner), and delivery is redirected to notify_user's companion.
RSpec.describe "Buddy cross-user watches" do
  let(:rocco)   { create(:user) }
  let(:chelsea) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: rocco) }
  let!(:rocco_convo) { ByteConversation.create!(user: rocco, mode: :buddy, name: "Buddy") }

  before do
    # ChoreHousehold auto-adds its owner (rocco) as a manager member.
    ChoreHouseholdMembership.create!(chore_household: household, user: chelsea, role: :member)
    rocco.update!(chore_household_id: household.id)
    chelsea.update!(chore_household_id: household.id)

    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
    allow(Buddy::CompanionDelivery).to receive(:deliver_plain)
  end

  describe "WatchMatcher.fire! with a notify_user" do
    it "delivers to the notify_user's companion, not the owner's" do
      convo = ByteConversation.create!(user: rocco, mode: :buddy, name: "Buddy2")
      watch = BuddyWatch.create!(
        user: chelsea, notify_user: rocco, byte_conversation: convo,
        kind: "prompt", body: "something landed on the shared agenda",
        trigger_scope: "agenda_item", match: { "action" => "created" }, one_shot: false
      )

      Buddy::WatchMatcher.fire!(watch, { name: "Vet appt" })

      expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt)
        .with(hash_including(user: rocco))
      expect(watch.reload.last_fired_at).to be_present
    end
  end

  describe "remind_when agenda trigger" do
    it "owns the watch by the calendar's owner and routes the heads-up to the requester" do
      # Chelsea owns the shared calendar; Rocco (editor) sets up the watch.
      agenda = Agenda.create!(user: chelsea, name: "Ours")
      AgendaShare.create!(agenda: agenda, user: rocco, permission: :editor)

      tool = Buddy::Tools[:remind_when]
      ctx  = Buddy::ToolContext.new(rocco, conversation: rocco_convo)
      payload = { text: "something was added to Ours", trigger: :agenda, target: "Ours", repeat: true }
      confirm = tool[:confirm].call(payload, ctx)
      tool[:execute].call(payload.merge(confirm[:resolved]), ctx)

      watch = BuddyWatch.last
      expect(watch.trigger_scope).to eq("agenda_item")
      expect(watch.user).to eq(chelsea)            # owner, so the trigger reaches it
      expect(watch.notify_user).to eq(rocco)       # requester still gets told
      expect(watch.match["agenda_id"]).to eq(agenda.id)
    end

    it "sends a household member a heads-up on their own trigger (notify arg)" do
      tool = Buddy::Tools[:remind_when]
      ctx  = Buddy::ToolContext.new(rocco, conversation: rocco_convo)
      payload = { text: "Rocco finished the dishes", trigger: :chore, target: "dishes", notify: chelsea.username, repeat: true }
      confirm = tool[:confirm].call(payload, ctx)
      result  = tool[:execute].call(payload.merge(confirm[:resolved]), ctx)

      watch = BuddyWatch.last
      expect(watch.user).to eq(rocco)              # fires on Rocco's own chore
      expect(watch.notify_user).to eq(chelsea)
      expect(result[:recipient_name]).to eq(chelsea.first_name)
    end
  end

  describe "agenda_item is a watchable scope" do
    it "matches on agenda_id + created action" do
      watch = BuddyWatch.new(trigger_scope: "agenda_item", match: { "action" => "created", "agenda_id" => 42 })
      expect(watch.matches?({ action: "created", agenda_id: 42, name: "x" })).to be(true)
      expect(watch.matches?({ action: "created", agenda_id: 99 })).to be(false)
      expect(watch.matches?({ action: "updated", agenda_id: 42 })).to be(false)
    end
  end
end
