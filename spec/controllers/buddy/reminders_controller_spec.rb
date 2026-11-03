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
      trigger_scope: scope, listener: scope, **attrs
    )
  end

  def rows
    response.parsed_body["reminders"]
  end

  describe "GET #index" do
    # A turned-off one stays listed; one that has fired for good drops out.
    it "lists clock reminders and condition watches together, their own only", :aggregate_failures do
      reminder!(body: "Vet appt")
      reminder!(body: "Muted one", cancelled_at: 1.minute.ago)
      reminder!(body: "Long gone", fired_at: 1.hour.ago)
      watch!(body: "Grab prescription", metadata: { "human_when" => "when you get to Costco" })
      other = create(:user)
      other_convo = other.byte_conversations.create!(mode: :buddy)
      BuddyReminder.create!(user: other, byte_conversation: other_convo, body: "Not yours", fire_at: 1.hour.from_now)

      get :index

      expect(response).to be_successful
      expect(rows.pluck("label")).to contain_exactly("Vet appt", "Muted one", "Grab prescription")
      expect(rows.pluck("type")).to contain_exactly("reminder", "reminder", "watch")
      expect(rows.find { |r| r["label"] == "Muted one" }["enabled"]).to be(false)
      expect(rows.find { |r| r["type"] == "watch" }["sublabel"]).to eq("when you get to Costco\ntravel")
    end
  end

  describe "PATCH #update" do
    it "turns a reminder or a watch off without losing it, and back on" do
      rem = reminder!
      w = watch!

      patch :update, params: { type: :reminder, id: rem.id, reminder: { enabled: false } }
      expect(response).to be_successful
      expect(rem.reload.cancelled_at).to be_present
      expect(rows.find { |r| r["record_id"] == rem.id }["enabled"]).to be(false)

      patch :update, params: { type: :reminder, id: rem.id, reminder: { enabled: true } }
      expect(rem.reload.cancelled_at).to be_nil

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

  # The wording and the hour are the two things that turn out wrong.
  describe "PATCH #update, editing it" do
    let(:zone) { ActiveSupport::TimeZone[user.timezone] }

    it "rewrites the words of a reminder or a watch" do
      rem = reminder!(body: "Vet appt")
      w = watch!(body: "Grab prescription")

      patch :update, params: { type: :reminder, id: rem.id, reminder: { body: "Vet appt - bring the carrier" } }
      patch :update, params: { type: :watch, id: w.id, reminder: { body: "Grab the prescription and the cat food" } }

      expect(rem.reload.body).to eq("Vet appt - bring the carrier")
      expect(w.reload.body).to eq("Grab the prescription and the cat food")
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
    it "refuses a time that's already gone, or blank words, leaving it as it was" do
      rem = reminder!(body: "Vet appt", fire_at: 2.hours.from_now)
      was = rem.fire_at
      gone = 2.hours.ago.in_time_zone(zone).strftime("%Y-%m-%dT%H:%M")

      [{ at: gone }, { body: "  " }].each do |edit|
        patch :update, params: { type: :reminder, id: rem.id, reminder: edit }
        expect(response).to have_http_status(:unprocessable_entity)
      end
      expect(rem.reload.fire_at).to be_within(1.second).of(was)
      expect(rem.body).to eq("Vet appt")
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

    it "hands the editor the raw values rather than the display ones" do
      rem = reminder!(body: "A" * 120)

      get :index
      row = rows.find { |r| r["record_id"] == rem.id }

      expect(row["label"].length).to be < 120  # truncated for the list
      expect(row["body"].length).to eq(120)    # what the field starts on
      expect(row["at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/)
    end
  end

  # The repeat RULE, not just its hour.
  describe "PATCH #update, changing how it repeats" do
    let(:zone) { ActiveSupport::TimeZone[user.timezone] }

    # A row written before reminders and the calendar shared a vocabulary edits
    # as though it had always been in the new one.
    it "hands the editor the rule it's on, in parts, translating the old shape" do
      current = reminder!(body: "New", recurrence: { "freq" => "weekly", "by_day" => ["tue"], "at" => "07:54" })
      legacy = reminder!(body: "Old", recurrence: { "kind" => "weekly", "weekday" => "tuesday", "at" => "07:54" })

      get :index

      [current, legacy].each do |rem|
        row = rows.find { |r| r["record_id"] == rem.id }
        expect(row).to include("freq" => "weekly", "by_day" => ["tue"], "at" => "07:54")
      end
    end

    it "switches weekdays to every day" do
      rem = reminder!(recurrence: { "freq" => "weekdays", "at" => "07:54" })

      patch :update, params: { type: :reminder, id: rem.id, reminder: { freq: "daily" } }

      expect(response).to be_successful
      expect(rem.reload.recurrence["freq"]).to eq("daily")
      expect(rem.recurrence["at"]).to eq("07:54")
    end

    it "takes weekdays, one or several, when they switch to weekly" do
      rem = reminder!(recurrence: { "freq" => "daily", "at" => "09:00" })

      patch :update, params: { type: :reminder, id: rem.id, reminder: { freq: "weekly", by_day: %w[wed] } }
      expect(rem.reload.recurrence["by_day"]).to eq(["wed"])
      expect(rem.fire_at.in_time_zone(zone).strftime("%A").downcase).to eq("wednesday")

      patch :update, params: { type: :reminder, id: rem.id, reminder: { freq: "weekly", by_day: %w[mon wed fri] } }
      expect(rem.reload.recurrence["by_day"]).to eq(%w[mon wed fri])
    end

    it "takes a date when they switch to monthly" do
      rem = reminder!(recurrence: { "freq" => "daily", "at" => "09:00" })

      patch :update, params: { type: :reminder, id: rem.id, reminder: { freq: "monthly", by_month_day: [12] } }

      expect(rem.reload.recurrence["by_month_day"]).to eq([12])
      expect(rem.fire_at.in_time_zone(zone).day).to eq(12)
    end

    # The request this whole thing started from.
    it "takes the second Tuesday of the month" do
      rem = reminder!(recurrence: { "freq" => "daily", "at" => "09:00" })

      edit = { freq: "monthly", by_set_pos: 2, by_day: %w[tue] }
      patch :update, params: { type: :reminder, id: rem.id, reminder: edit }

      expect(response).to be_successful
      expect(rem.reload.recurrence).to include("by_set_pos" => 2, "by_day" => ["tue"])
      fired = rem.fire_at.in_time_zone(zone)
      expect(fired.strftime("%A")).to eq("Tuesday")
      expect(((fired.day - 1) / 7) + 1).to eq(2)
    end

    it "takes every other week" do
      rem = reminder!(recurrence: { "freq" => "daily", "at" => "09:00" })

      edit = { freq: "custom", interval: 2, unit: "week" }
      patch :update, params: { type: :reminder, id: rem.id, reminder: edit }

      expect(response).to be_successful
      expect(rem.reload.recurrence).to include("freq" => "custom", "interval" => 2, "unit" => "week")
    end

    it "takes the last Friday of the month" do
      rem = reminder!(recurrence: { "freq" => "daily", "at" => "09:00" })

      edit = { freq: "monthly", by_set_pos: -1, by_day: %w[fri] }
      patch :update, params: { type: :reminder, id: rem.id, reminder: edit }

      fired = rem.reload.fire_at.in_time_zone(zone)
      expect(fired.strftime("%A")).to eq("Friday")
      expect((fired.to_date + 7).month).not_to eq(fired.month)
    end

    it "takes an end date, and lets it be cleared again" do
      rem = reminder!(recurrence: { "freq" => "daily", "at" => "09:00" })
      ends = 30.days.from_now.to_date

      patch :update, params: { type: :reminder, id: rem.id, reminder: { until_on: ends.iso8601 } }
      expect(rem.reload.recurrence["until_on"]).to eq(ends.iso8601)

      patch :update, params: { type: :reminder, id: rem.id, reminder: { until_on: "" } }
      expect(rem.reload.recurrence).not_to have_key("until_on")
    end

    # A weekly-turned-daily keeping its weekday would mean switching back later
    # silently reuses a day they picked months ago.
    it "drops the anchor that no longer applies" do
      rem = reminder!(recurrence: { "freq" => "weekly", "by_day" => ["tue"], "at" => "09:00" })

      patch :update, params: { type: :reminder, id: rem.id, reminder: { freq: "daily" } }

      expect(rem.reload.recurrence).not_to have_key("by_day")
    end

    it "drops the nth-weekday when they go back to picking dates" do
      rem = reminder!(recurrence: { "freq" => "monthly", "by_set_pos" => 2, "by_day" => ["tue"], "at" => "09:00" })

      patch :update, params: { type: :reminder, id: rem.id, reminder: { freq: "monthly", by_month_day: [3] } }

      expect(rem.reload.recurrence).not_to have_key("by_set_pos")
      expect(rem.recurrence["by_month_day"]).to eq([3])
    end

    it "changes the rule and the hour in one go" do
      rem = reminder!(recurrence: { "freq" => "weekdays", "at" => "07:54" })

      edit = { freq: "weekly", by_day: %w[fri], at: "18:15" }
      patch :update, params: { type: :reminder, id: rem.id, reminder: edit }

      expect(rem.reload.recurrence).to include("freq" => "weekly", "by_day" => ["fri"], "at" => "18:15")
    end

    it "refuses an unknown repeat, a set position that isn't a week of the month, or a past end date" do
      rem = reminder!(recurrence: { "freq" => "daily", "at" => "09:00" })

      [
        { freq: "fortnightly" },
        { freq: "monthly", by_set_pos: 9 },
        { until_on: 2.days.ago.to_date.iso8601 },
      ].each do |edit|
        patch :update, params: { type: :reminder, id: rem.id, reminder: edit }
        expect(response).to have_http_status(:unprocessable_entity), edit.to_s
      end
      expect(rem.reload.recurrence).to eq("freq" => "daily", "at" => "09:00")
    end

    it "leaves a one-off alone" do
      rem = reminder!(fire_at: 2.hours.from_now)
      was = rem.fire_at

      patch :update, params: { type: :reminder, id: rem.id, reminder: { freq: "daily" } }

      expect(rem.reload.recurrence).to be_blank
      expect(rem.fire_at).to be_within(1.second).of(was)
    end

    # Recomputing the next firing is what rescheduling MEANS, so it can't ride
    # along on an edit that didn't ask for it.
    it "does not roll the next firing when only the switch was flipped, or the words changed" do
      rem = reminder!(fire_at: 30.minutes.from_now, recurrence: { "freq" => "daily", "at" => "09:00" })
      was = rem.fire_at

      patch :update, params: { type: :reminder, id: rem.id, reminder: { enabled: false } }
      expect(rem.reload.fire_at).to be_within(1.second).of(was)

      patch :update, params: { type: :reminder, id: rem.id, reminder: { body: "Grab the Loops" } }
      expect(rem.reload.body).to eq("Grab the Loops")
      expect(rem.fire_at).to be_within(1.second).of(was)
    end
  end

  # The body is a Liquid template, so the editor needs to know before saving
  # whether it'll run and what it'll say.
  describe "templates" do
    it "saves one that parses" do
      rem = reminder!(body: "Bins out")

      patch :update, params: { type: :reminder, id: rem.id, reminder: { body: "{{ greeting }} - bins out" } }

      expect(response).to be_successful
      expect(rem.reload.body).to eq("{{ greeting }} - bins out")
    end

    # Rendering falls back to the raw text so a broken one is never silent, but
    # SAVING markup that can never run is a trap - it looks like a template.
    it "refuses one that never will" do
      rem = reminder!(body: "Bins out")

      patch :update, params: { type: :reminder, id: rem.id, reminder: { body: "{% if x %}no end" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(rem.reload.body).to eq("Bins out")
    end

    describe "POST #preview" do
      it "says what a template would come out as, with the variables on offer" do
        post :preview, params: { body: "{{ name | remove: '>' }} landed", vars: { name: ">main Done" } }

        expect(response).to be_successful
        expect(response.parsed_body["preview"]).to eq("main Done landed")
        expect(response.parsed_body["error"]).to be_nil
        expect(response.parsed_body["variables"]).to include("weekday", "buddy", "user")
      end

      it "explains a broken one instead of failing the request" do
        post :preview, params: { body: "{% if x %}no end" }

        expect(response).to be_successful
        expect(response.parsed_body["error"]).to be_present
        expect(response.parsed_body["preview"]).to be_nil
      end
    end
  end

  # The condition was held back on the theory that a half-edited listener looks
  # set and never fires. True, and already covered: BuddyWatch refuses to save
  # one Jil wouldn't match, so a bad edit bounces with the old one intact.
  describe "PATCH #update, retargeting a watch" do
    it "hands the editor the listener it's matching on" do
      watch!(scope: "item", listener: "item:action:added")

      get :index
      row = rows.find { |r| r["type"] == "watch" }

      expect(row["listener"]).to eq("item:action:added")
      expect(row["custom"]).to be(true)
      expect(row["at"]).to be_nil
    end

    it "narrows a watch to one list, and follows the listener when its scope changes" do
      w = watch!(scope: "item", listener: "item:action:added")

      narrowed = "item:action:added item:list:name:/^Claude$/"
      patch :update, params: { type: :watch, id: w.id, reminder: { listener: narrowed } }
      expect(response).to be_successful
      expect(w.reload.listener).to eq(narrowed)

      patch :update, params: { type: :watch, id: w.id, reminder: { listener: "event:add" } }
      expect(response).to be_successful
      expect(w.reload.trigger_scope).to eq("event")
    end

    it "keeps the old condition when the new one would never fire, or is blank" do
      w = watch!(scope: "item", listener: "item:action:added")

      ["!!! nonsense", "  "].each do |listener|
        patch :update, params: { type: :watch, id: w.id, reminder: { listener: listener } }
        expect(response).to have_http_status(:unprocessable_entity)
      end
      expect(w.reload.listener).to eq("item:action:added")
    end

    # A watch for "today" needs something that retires it.
    describe "how long it stays armed" do
      it "sets an expiry to the END of that day, not the moment it starts" do
        w = watch!(scope: "item", listener: "item:action:added")
        ends = 2.days.from_now.to_date

        patch :update, params: { type: :watch, id: w.id, reminder: { expires_on: ends.iso8601 } }

        expect(response).to be_successful
        local = w.reload.expires_at.in_time_zone(user.timezone)
        expect(local.to_date).to eq(ends)
        expect(local.hour).to eq(23)
      end


      # Their end of day, not the server's. Time.zone is UTC app-wide, so a bare
      # end_of_day is already tomorrow on a UTC-6 calendar from 6pm onwards —
      # and the row was right to say "tomorrow", which made this fail every
      # evening.
      it "says on the row that it stops on its own" do
        watch!(
          scope:      "item",
          listener:   "item:action:added",
          expires_at: Time.current.in_time_zone(user.timezone).end_of_day,
        )

        get :index

        expect(rows.find { |r| r["type"] == "watch" }["sublabel"]).to include("until tonight")
      end

      it "hands the date back to the editor, and clears it back to a standing watch" do
        w = watch!(scope: "item", listener: "item:action:added", expires_at: 3.days.from_now)

        get :index
        expect(rows.find { |r| r["type"] == "watch" }["expires_on"]).to be_present

        patch :update, params: { type: :watch, id: w.id, reminder: { expires_on: "" } }

        expect(w.reload.expires_at).to be_nil
      end

      it "refuses a day already behind us" do
        w = watch!(scope: "item", listener: "item:action:added")

        patch :update, params: { type: :watch, id: w.id, reminder: { expires_on: 2.days.ago.to_date.iso8601 } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(w.reload.expires_at).to be_nil
      end

      it "leaves a reminder's own fields alone" do
        rem = reminder!(fire_at: 2.hours.from_now)

        patch :update, params: { type: :reminder, id: rem.id, reminder: { expires_on: 3.days.from_now.to_date.iso8601 } }

        expect(response).to be_successful
      end
    end

    # A named trigger writes a listener too, so its condition is editable
    # like any other watch's.
    it "lets a named trigger's condition be retyped" do
      w = watch!(scope: "travel", body: "Grab prescription", listener: "travel:action::arrived near(40.5 -111.9)")

      get :index
      row = rows.find { |r| r["type"] == "watch" }
      expect(row["custom"]).to be(true)
      expect(row["listener"]).to eq("travel:action::arrived near(40.5 -111.9)")

      patch :update, params: { type: :watch, id: w.id, reminder: { listener: "travel:action::arrived -near(40.5 -111.9)" } }
      expect(response).to be_successful
      expect(w.reload.listener).to eq("travel:action::arrived -near(40.5 -111.9)")
    end
  end

  describe "DELETE #destroy" do
    it "deletes a reminder or a watch outright" do
      rem = reminder!
      w = watch!

      delete :destroy, params: { type: :reminder, id: rem.id }
      expect(response).to have_http_status(:no_content)
      delete :destroy, params: { type: :watch, id: w.id }

      expect(BuddyReminder.exists?(rem.id)).to be(false)
      expect(BuddyWatch.exists?(w.id)).to be(false)
    end
  end

  it "refuses anyone who can't open Byte at all" do
    sign_in create(:user)

    get :index

    expect(response).to have_http_status(:forbidden)
  end
end
