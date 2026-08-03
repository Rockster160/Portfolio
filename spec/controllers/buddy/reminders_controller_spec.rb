require "rails_helper"

# The Reminders manager behind the drawer. Clock reminders and condition
# watches are separate tables but one list here, so `type` picks the table and
# the pair is the identity.
#
# The rule the whole panel turns on: turning one OFF keeps it listed. If a
# muted reminder dropped out of the list, off would be a one-way door and the
# only way back would be setting the whole thing up again - which is the exact
# thing this exists to save you from.
RSpec.describe Buddy::RemindersController, type: :controller do
  let(:user) { create(:user, id: 4) } # someone with Byte access
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before { sign_in user }

  def reminder!(body: "Vet appt", fire_at: 2.hours.from_now, **attrs)
    BuddyReminder.create!(user: user, byte_conversation: convo, body: body, fire_at: fire_at, **attrs)
  end

  def watch!(body: "Grab prescription", scope: "travel", **attrs)
    BuddyWatch.create!(
      user: user, byte_conversation: convo, kind: "prompt", body: body,
      trigger_scope: scope, match: {}, **attrs
    )
  end

  def rows
    response.parsed_body["reminders"]
  end

  describe "GET #index" do
    it "lists clock reminders and condition watches together" do
      reminder!(body: "Vet appt")
      watch!(body: "Grab prescription", metadata: { "human_when" => "when you get to Costco" })

      get :index

      expect(response).to be_successful
      expect(rows.pluck("label")).to contain_exactly("Vet appt", "Grab prescription")
      expect(rows.pluck("type")).to contain_exactly("reminder", "watch")
      expect(rows.find { |r| r["type"] == "watch" }["sublabel"]).to eq("when you get to Costco")
    end

    it "keeps a turned-off one listed, marked off" do
      reminder!(body: "Muted one", cancelled_at: 1.minute.ago)

      get :index

      expect(rows.pluck("label")).to include("Muted one")
      expect(rows.find { |r| r["label"] == "Muted one" }["enabled"]).to be(false)
    end

    it "drops one that has already fired for good" do
      reminder!(body: "Long gone", fired_at: 1.hour.ago)

      get :index

      expect(rows).to be_empty
    end

    it "leaves someone else's reminders out of it" do
      other = create(:user)
      other_convo = other.byte_conversations.create!(mode: :buddy)
      BuddyReminder.create!(user: other, byte_conversation: other_convo, body: "Not yours", fire_at: 1.hour.from_now)

      get :index

      expect(rows).to be_empty
    end
  end

  describe "PATCH #update" do
    it "turns a reminder off without losing it" do
      rem = reminder!

      patch :update, params: { type: :reminder, id: rem.id, reminder: { enabled: false } }

      expect(response).to be_successful
      expect(rem.reload.cancelled_at).to be_present
      expect(rows.find { |r| r["record_id"] == rem.id }["enabled"]).to be(false)
    end

    it "turns one back on" do
      rem = reminder!(cancelled_at: 1.minute.ago)

      patch :update, params: { type: :reminder, id: rem.id, reminder: { enabled: true } }

      expect(rem.reload.cancelled_at).to be_nil
    end

    it "does the same for a watch" do
      w = watch!

      patch :update, params: { type: :watch, id: w.id, reminder: { enabled: false } }

      expect(w.reload.cancelled_at).to be_present
    end

    it "refuses to touch someone else's" do
      other = create(:user)
      other_convo = other.byte_conversations.create!(mode: :buddy)
      theirs = BuddyReminder.create!(user: other, byte_conversation: other_convo, body: "Not yours", fire_at: 1.hour.from_now)

      patch :update, params: { type: :reminder, id: theirs.id, reminder: { enabled: false } }

      expect(response).to have_http_status(:not_found)
      expect(theirs.reload.cancelled_at).to be_nil
    end
  end

  describe "DELETE #destroy" do
    it "deletes a reminder outright" do
      rem = reminder!

      delete :destroy, params: { type: :reminder, id: rem.id }

      expect(response).to have_http_status(:no_content)
      expect(BuddyReminder.exists?(rem.id)).to be(false)
    end

    it "deletes a watch outright" do
      w = watch!

      delete :destroy, params: { type: :watch, id: w.id }

      expect(BuddyWatch.exists?(w.id)).to be(false)
    end
  end

  it "refuses anyone who can't open Byte at all" do
    sign_in create(:user)

    get :index

    expect(response).to have_http_status(:forbidden)
  end
end
