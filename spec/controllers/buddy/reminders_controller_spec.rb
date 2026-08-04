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

  # The wording and the hour are the two things that turn out wrong, and until
  # now the only fix was cancelling and setting the whole thing up again by
  # talking it through.
  describe "PATCH #update, editing it" do
    let(:zone) { ActiveSupport::TimeZone[user.timezone] }

    it "rewrites the words" do
      rem = reminder!(body: "Vet appt")

      patch :update, params: { type: :reminder, id: rem.id, reminder: { body: "Vet appt - bring the carrier" } }

      expect(rem.reload.body).to eq("Vet appt - bring the carrier")
    end

    it "moves the time, reading it as their local clock" do
      rem = reminder!(fire_at: 2.hours.from_now)
      at  = 3.hours.from_now.in_time_zone(zone)

      patch :update, params: { type: :reminder, id: rem.id, reminder: { at: at.strftime("%Y-%m-%dT%H:%M") } }

      expect(response).to be_successful
      expect(rem.reload.fire_at.in_time_zone(zone).strftime("%Y-%m-%dT%H:%M")).to eq(at.strftime("%Y-%m-%dT%H:%M"))
    end

    # Saving one into the past means it goes off on the next sweep, seconds
    # later, which is never what a mistyped date meant.
    it "refuses a time that's already gone" do
      rem = reminder!(fire_at: 2.hours.from_now)
      was = rem.fire_at

      gone = 2.hours.ago.in_time_zone(zone).strftime("%Y-%m-%dT%H:%M")
      patch :update, params: { type: :reminder, id: rem.id, reminder: { at: gone } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(rem.reload.fire_at).to be_within(1.second).of(was)
    end

    it "refuses to blank the words out" do
      rem = reminder!(body: "Vet appt")

      patch :update, params: { type: :reminder, id: rem.id, reminder: { body: "  " } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(rem.reload.body).to eq("Vet appt")
    end

    # A recurring one keeps its shape; only the hour moves, and the next firing
    # is recomputed from it.
    it "moves the hour of a recurring one and rolls the next firing" do
      rem = reminder!(recurrence: { "kind" => "daily", "at" => "09:00" })

      patch :update, params: { type: :reminder, id: rem.id, reminder: { at: "07:30" } }

      expect(response).to be_successful
      expect(rem.reload.recurrence["at"]).to eq("07:30")
      expect(rem.fire_at.in_time_zone(zone).strftime("%H:%M")).to eq("07:30")
    end

    it "lets a watch's words be edited" do
      w = watch!(body: "Grab prescription")

      patch :update, params: { type: :watch, id: w.id, reminder: { body: "Grab the prescription and the cat food" } }

      expect(w.reload.body).to eq("Grab the prescription and the cat food")
    end

    # The one thing this panel must not be able to rewrite: a listener is
    # validated when it's written, and a half-edited one looks set and never
    # fires.
    it "gives a watch no time to move and no condition to edit" do
      w = watch!(scope: "item", listener: "item:action:added")

      get :index
      row = rows.find { |r| r["type"] == "watch" }

      expect(row["at"]).to be_nil
      expect(row.keys).not_to include("listener")
    end

    it "hands the editor the raw values rather than the display ones" do
      rem = reminder!(body: "A" * 120)

      get :index
      row = rows.find { |r| r["record_id"] == rem.id }

      expect(row["label"].length).to be < 120  # truncated for the list
      expect(row["body"].length).to eq(120)    # what the field starts on
      expect(row["at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/)
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
