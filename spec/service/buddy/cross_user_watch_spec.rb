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

  # A watch aimed at somebody else is a message from whoever set it, waiting on
  # a condition instead of a clock — so it goes out bridged, exactly like an
  # immediate message_partner, rather than poking the recipient's companion with
  # a seed. That's what leaves the sender a copy saying it went.
  describe "WatchMatcher.fire! with a notify_user" do
    def fire!
      convo = ByteConversation.create!(user: chelsea, mode: :buddy, name: "Hers")
      watch = BuddyWatch.create!(
        user: chelsea, notify_user: rocco, byte_conversation: convo,
        kind: "prompt", body: "something landed on the shared agenda",
        trigger_scope: "agenda_item", match: { "action" => "created" }, one_shot: false
      )
      Buddy::WatchMatcher.fire!(watch, { name: "Vet appt" })
      watch
    end

    it "passes it to the recipient as a message from whoever set it" do
      watch = fire!

      relay = BuddyRelay.last
      expect(relay.from_user).to eq(chelsea)
      expect(relay.to_user).to eq(rocco)
      expect(watch.reload.last_fired_at).to be_present
    end

    it "carries the same wording a self-fired watch would, detail and all" do
      fire!

      expect(BuddyRelay.last.body).to include("something landed on the shared agenda")
      expect(BuddyRelay.last.body).to include("Vet appt")
    end

    it "leaves the sender the copy that says it went" do
      fire!

      copy = chelsea.byte_messages.where("metadata->>'source' = 'relay_copy'").last
      expect(copy).to be_present
      expect(copy.body).to include("something landed on the shared agenda")
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
