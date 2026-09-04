require "rails_helper"

RSpec.describe AgendaItemsController, type: :controller do
  describe "the controller" do
    let(:user) { create(:user) }
    let!(:agenda) { create(:agenda, user: user) }

    before { sign_in user }

    describe "client_mutation_id idempotency" do
      # Offline-first contract — every PWA mutation carries a client-generated
      # UUID. The server stores it on the row and dedupes on retry so a
      # replayed POST (queue drained twice, two tabs, browser killed
      # mid-flight) never creates duplicates.
      it "POST: stores client_mutation_id and dedupes a retry with the same id" do
        mid = SecureRandom.uuid
        expect {
          post :create, params: {
            agenda_item: {
              agenda_id:           agenda.id,
              name:                "Coffee",
              kind:                "task",
              start_at:            Time.current.to_i,
              client_mutation_id:  mid,
            },
          }, format: :json
        }.to change(AgendaItem, :count).by(1)
        created = AgendaItem.order(created_at: :desc).first
        expect(created.client_mutation_id).to eq(mid)
        body = JSON.parse(response.body)
        expect(body["client_mutation_id"]).to eq(mid)

        # Replay — must NOT create a second row, must return the same one.
        expect {
          post :create, params: {
            agenda_item: {
              agenda_id:           agenda.id,
              name:                "Coffee (retry — should dedupe)",
              kind:                "task",
              start_at:            Time.current.to_i,
              client_mutation_id:  mid,
            },
          }, format: :json
        }.not_to change(AgendaItem, :count)
        retry_body = JSON.parse(response.body)
        expect(retry_body["id"]).to eq(created.id.to_s)
        expect(retry_body["name"]).to eq("Coffee") # original, not the retry's body
        expect(retry_body["deduped"]).to be(true)
      end

      it "PATCH: dedupes a retry whose client_mutation_id matches what's already on the row" do
        mid = SecureRandom.uuid
        item = create(:agenda_item, agenda: agenda, kind: :task, name: "Original",
          start_at: Time.current, client_mutation_id: mid)
        patch :update, params: {
          id:          item.id,
          agenda_item: { name: "Should not apply", client_mutation_id: mid },
        }, format: :json
        expect(response).to be_successful
        body = JSON.parse(response.body)
        expect(body["deduped"]).to be(true)
        expect(item.reload.name).to eq("Original")
      end

      it "serializes client_mutation_id on the response so the FE can match optimistic state" do
        mid = SecureRandom.uuid
        post :create, params: {
          agenda_item: {
            agenda_id:           agenda.id,
            name:                "X",
            kind:                "task",
            start_at:            Time.current.to_i,
            client_mutation_id:  mid,
          },
        }, format: :json
        body = JSON.parse(response.body)
        expect(body["client_mutation_id"]).to eq(mid)
        expect(body["presentation_attrs"]).to be_present # canonical row payload too
      end
    end

    describe "X-Client-Mutation-At conflict resolution" do
      # Every JS mutation (offline-queued OR online) stamps the request
      # with the wall-clock moment the user actually clicked / typed.
      # Server compares against the row's current updated_at so a stale
      # offline edit can't clobber a fresher edit that happened on
      # another device while the first device was disconnected.
      let!(:item) {
        create(
          :agenda_item, agenda: agenda, kind: :task, name: "Original",
          start_at: Time.current,
        )
      }

      it "accepts an edit whose client_ts is newer than the row's updated_at" do
        future_ms = ((item.updated_at + 1.minute).to_f * 1000).round
        request.headers["X-Client-Mutation-At"] = future_ms.to_s
        patch :update, params: {
          id:          item.id,
          agenda_item: { name: "Renamed by fresher edit" },
        }, format: :json
        expect(response).to be_successful
        expect(item.reload.name).to eq("Renamed by fresher edit")
      end

      it "rejects an edit whose client_ts predates the row's updated_at (409 with canonical current row)" do
        # Simulate another device having touched the row 30s ago.
        item.update_columns(updated_at: Time.current, name: "Already touched by other device")
        stale_ms = ((item.updated_at - 60.seconds).to_f * 1000).round
        request.headers["X-Client-Mutation-At"] = stale_ms.to_s

        patch :update, params: {
          id:          item.id,
          agenda_item: { name: "Stale edit that should NOT apply" },
        }, format: :json

        expect(response).to have_http_status(:conflict)
        body = JSON.parse(response.body)
        expect(body["current"]).to be_present
        expect(body["current"]["name"]).to eq("Already touched by other device")
        expect(item.reload.name).to eq("Already touched by other device")
      end

      it "accepts edits with no client_ts header (back-compat with older callers / non-PWA clients)" do
        patch :update, params: {
          id:          item.id,
          agenda_item: { name: "No header — should still work" },
        }, format: :json
        expect(response).to be_successful
        expect(item.reload.name).to eq("No header — should still work")
      end

      it "ignores a malformed client_ts header without 500" do
        request.headers["X-Client-Mutation-At"] = "not a number"
        patch :update, params: {
          id:          item.id,
          agenda_item: { name: "Garbage header, sane response" },
        }, format: :json
        expect(response).to be_successful
        expect(item.reload.name).to eq("Garbage header, sane response")
      end

      it "rejects a stale destroy too — not just updates" do
        item.update_columns(updated_at: Time.current)
        stale_ms = ((item.updated_at - 60.seconds).to_f * 1000).round
        request.headers["X-Client-Mutation-At"] = stale_ms.to_s

        expect { delete :destroy, params: { id: item.id } }
          .not_to change { AgendaItem.exists?(item.id) }
        expect(response).to have_http_status(:conflict)
      end
    end

    describe "PATCH #update with location/notes (regression)" do
      let!(:item) {
        create(
          :agenda_item, agenda: agenda, kind: :task, name: "Task",
          start_at: Time.current, location: "", notes: ""
        )
      }

      it "persists location and notes on a non-recurring item" do
        patch :update, params: {
          id:          item.id,
          agenda_item: {
            agenda_id: agenda.id,
            name:      "Task",
            location:  "Living room",
            notes:     "Bring tools",
          },
        }, format: :json
        item.reload
        expect(item.location).to eq("Living room")
        expect(item.notes).to eq("Bring tools")
      end

      it "persists location and notes when scope=occurrence on a recurring item" do
        sched = create(
          :agenda_schedule, agenda: agenda, kind: :task, name: "Daily",
          start_time: "09:00", recurrence: { "freq" => "daily" }, starts_on: Date.current
        )
        occ = sched.agenda_items.create!(
          agenda: agenda, kind: :task, name: "Daily",
          start_at: Time.current, detached_at: Time.current
        )
        patch :update, params: {
          id:          occ.id,
          scope:       :occurrence,
          agenda_item: { agenda_id: agenda.id, name: "Daily", location: "Office", notes: "Sync" },
        }, format: :json
        occ.reload
        expect(occ.location).to eq("Office")
        expect(occ.notes).to eq("Sync")
      end

      it "persists location and notes when scope=series on a recurring item" do
        sched = create(
          :agenda_schedule, agenda: agenda, kind: :task, name: "Daily",
          start_time: "09:00", recurrence: { "freq" => "daily" }, starts_on: Date.current
        )
        phantom_id = "p-#{sched.id}-#{(Date.current + 5.days).iso8601}"
        patch :update, params: {
          id:          phantom_id,
          scope:       :series,
          agenda_item: { agenda_id: agenda.id, name: "Daily", location: "HQ", notes: "All-hands" },
        }, format: :json
        sched.reload
        expect(sched.location).to eq("HQ")
        expect(sched.notes).to eq("All-hands")
      end

      it "persists location and notes on a series edit when the full agenda_schedule payload is sent" do
        # Mirrors what the JS sends when editing a recurring item in series mode:
        # an `agenda_schedule` block including the new location/notes (regression
        # check for the bug where the JS forgot to merge them into the payload).
        sched = create(
          :agenda_schedule, agenda: agenda, kind: :task, name: "Daily",
          start_time: "09:00", recurrence: { "freq" => "daily" }, starts_on: Date.current
        )
        phantom_id = "p-#{sched.id}-#{(Date.current + 5.days).iso8601}"
        patch :update, params: {
          id:              phantom_id,
          scope:           :series,
          agenda_item:     { agenda_id: agenda.id, name: "Daily", location: "HQ", notes: "All-hands" },
          agenda_schedule: {
            name:       "Daily",
            kind:       "task",
            color:      "#0160ff",
            start_time: "09:00",
            starts_on:  Date.current.iso8601,
            recurrence: { freq: "daily" },
            location:   "HQ",
            notes:      "All-hands",
          },
        }, format: :json
        sched.reload
        expect(sched.location).to eq("HQ")
        expect(sched.notes).to eq("All-hands")
      end
    end

    describe "PATCH #update with travel_nav_address" do
      let!(:item) {
        create(
          :agenda_item, agenda: agenda, kind: :event, name: "Eyebrow appointment",
          start_at: Time.current, end_at: Time.current + 1.hour, location: "Eyebrow appointment"
        )
      }

      it "persists the nav-address override on a non-recurring item" do
        patch :update, params: {
          id:          item.id,
          agenda_item: {
            agenda_id:          agenda.id,
            name:               "Eyebrow appointment",
            location:           "Eyebrow appointment",
            travel_nav_address: "1234 S Main St, Denver CO",
          },
        }, format: :json
        item.reload
        expect(item.travel_nav_address).to eq("1234 S Main St, Denver CO")
        expect(item.location).to eq("Eyebrow appointment") # display name untouched
      end

      it "carries the nav-address override to the schedule on a series edit" do
        sched = create(
          :agenda_schedule, agenda: agenda, kind: :event, name: "Waxing",
          start_time: "09:00", duration_minutes: 60,
          recurrence: { "freq" => "weekly" }, starts_on: Date.current
        )
        phantom_id = "p-#{sched.id}-#{(Date.current + 7.days).iso8601}"
        patch :update, params: {
          id:              phantom_id,
          scope:           :series,
          agenda_item:     { agenda_id: agenda.id, name: "Waxing", location: "Waxing" },
          agenda_schedule: {
            name:               "Waxing",
            kind:               "event",
            start_time:         "09:00",
            starts_on:          Date.current.iso8601,
            recurrence:         { freq: "weekly" },
            location:           "Waxing",
            travel_nav_address: "1234 S Main St, Denver CO",
          },
        }, format: :json
        sched.reload
        expect(sched.travel_nav_address).to eq("1234 S Main St, Denver CO")
      end
    end

    describe "POST #create" do
      # `at_least` because the row announces itself on commit as well — see
      # AgendaItem#broadcast_agenda_refresh, which is what makes a create from
      # Byte or a script reach an open page. The controller keeps its own
      # broadcast for the paths that skip callbacks on purpose (`update_all`
      # on a series move), so a controller create says it twice. The client
      # coalesces both into one delta.
      it "creates a one-off task and broadcasts" do
        expect(MonitorChannel).to receive(:broadcast_to).with(user, hash_including(id: :agenda)).at_least(:once)
        expect {
          post :create, params: {
            agenda_item: { agenda_id: agenda.id, name: "Walk dog", kind: "task", start_at: Time.current.to_i },
          }, format: :json
        }.to change { agenda.agenda_items.count }.by(1)
      end

      it "returns 404 when the target agenda isn't accessible" do
        other_user = create(:user, phone: "5559876543")
        other = create(:agenda, user: other_user)
        post :create, params: {
          agenda_item: { agenda_id: other.id, name: "Sneaky", kind: "task", start_at: Time.current.to_i },
        }, format: :json
        expect(response).to have_http_status(:not_found)
      end

      it "creates into a shared agenda when the user is an editor" do
        other_user = create(:user, phone: "5559876543")
        shared = create(:agenda, user: other_user)
        AgendaShare.create!(agenda: shared, user: user, permission: :editor)
        expect {
          post :create, params: {
            agenda_item: { agenda_id: shared.id, name: "Team task", kind: "task", start_at: Time.current.to_i },
          }, format: :json
        }.to change { shared.agenda_items.count }.by(1)
      end

      it "rejects creation on a viewer-only shared agenda" do
        other_user = create(:user, phone: "5559876543")
        shared = create(:agenda, user: other_user)
        AgendaShare.create!(agenda: shared, user: user, permission: :viewer)
        post :create, params: {
          agenda_item: { agenda_id: shared.id, name: "Hands-off", kind: "task", start_at: Time.current.to_i },
        }, format: :json
        expect(response).to have_http_status(:not_found)
      end

      it "zeroes arrive_early_minutes on create when the location is non-travelable" do
        post :create, params: {
          agenda_item: {
            agenda_id:            agenda.id,
            name:                 "Standup",
            kind:                 "event",
            start_at:             Time.current.to_i,
            end_at:               (Time.current + 30.minutes).to_i,
            location:             "https://zoom.us/j/123",
            arrive_early_minutes: 5,
          },
        }, format: :json
        created = AgendaItem.order(created_at: :desc).first
        expect(created.location).to eq("https://zoom.us/j/123")
        expect(created.arrive_early_minutes).to eq(0)
      end

      it "keeps the arrive_early_minutes default when the location is blank" do
        post :create, params: {
          agenda_item: {
            agenda_id:            agenda.id,
            name:                 "Read book",
            kind:                 "task",
            start_at:             Time.current.to_i,
            arrive_early_minutes: 5,
          },
        }, format: :json
        created = AgendaItem.order(created_at: :desc).first
        expect(created.arrive_early_minutes).to eq(5)
      end
    end

    describe "moving an item between agendas" do
      let(:other) { create(:agenda, user: user, name: "Personal") }
      let(:item) { create(:agenda_item, agenda: agenda, kind: :task, name: "Walk", start_at: Time.current) }

      it "fires one combined broadcast covering both agendas" do
        _ = item
        payloads = []
        allow(MonitorChannel).to receive(:broadcast_to) { |_u, p| payloads << p }
        patch :update, params: {
          id:          item.id,
          agenda_item: { agenda_id: other.id, name: "Walk" },
        }, format: :json
        expect(item.reload.agenda_id).to eq(other.id)

        move_payload = payloads.find { |p| p.dig(:data, :changed)&.size == 2 }
        expect(move_payload).not_to be_nil
        ids = move_payload[:data][:changed].pluck(:agenda_id)
        expect(ids).to contain_exactly(agenda.id, other.id)
      end
    end

    describe "phantom interactions" do
      # `let!` so the schedule's after_save → materialize_upcoming! runs
      # in the test setup, not inside the `change(...).by(1)` block. The
      # daily standup pre-materializes tomorrow's occurrence on create;
      # without this, that row would count toward each test's count delta
      # and throw the assertions off by one.
      let!(:sched) {
        create(
          :agenda_schedule, agenda: agenda, name: "Standup", kind: "task",
          start_time: "09:00", recurrence: { "freq" => "daily" }, starts_on: Date.current
        )
      }
      let(:phantom_id) { "p-#{sched.id}-#{(Date.current + 30.days).iso8601}" }

      it "checking the box on a phantom materializes the row with completed_at" do
        expect {
          patch :update, params: {
            id:          phantom_id,
            agenda_item: { completed_at: "now" },
          }, format: :json
        }.to change(AgendaItem, :count).by(1)

        row = AgendaItem.last
        expect(row.agenda_schedule_id).to eq(sched.id)
        expect(row.completed_at).to be_present
      end

      # Regression: the real FE payload always carries `client_mutation_id`
      # alongside `completed_at` (mutation-queue durability). A stricter
      # `completion_only_update?` would route this through the generic update
      # path, where `item_params` runs `epoch_param_to_time("now")` and silently
      # writes nil — checkbox flipped, server cleared it on save, broadcast
      # reverted the FE. Lock the round-trip with the real payload shape.
      it "completes when the FE includes client_mutation_id with completed_at" do
        patch :update, params: {
          id:          phantom_id,
          agenda_item: { completed_at: "now", client_mutation_id: "cm-1" },
        }, format: :json

        expect(response).to be_successful, "body=#{response.body}"
        row = AgendaItem.last
        expect(row.completed_at).to be_present
        expect(row.client_mutation_id).to eq("cm-1")
      end

      it "occurrence-scope edit materializes + pins the date to excluded_dates" do
        patch :update, params: {
          id:          phantom_id,
          scope:       :occurrence,
          agenda_item: { name: "Custom name" },
        }, format: :json
        row = AgendaItem.last
        expect(row.name).to eq("Custom name")
        expect(row.detached_at).to be_present
        expect(sched.reload.excluded?(Date.current + 30.days)).to be true
      end

      it "occurrence-scope edit detaches but KEEPS the historical schedule link" do
        patch :update, params: {
          id:          phantom_id,
          scope:       :occurrence,
          agenda_item: { name: "One-off Standup" },
        }, format: :json
        row = AgendaItem.where(name: "One-off Standup").first
        expect(row).to be_present
        expect(row.agenda_schedule_id).to eq(sched.id) # historical link intact
        expect(row.detached_at).to be_present
        expect(row.original_start_at).to be_present
      end

      it "moving an occurrence to a date that already has the recurring event doesn't overwrite the other one" do
        target_date = Date.current + 30.days
        origin_date = Date.current + 29.days
        origin_phantom = "p-#{sched.id}-#{origin_date.iso8601}"
        origin_zone   = sched.send(:user_zone)
        target_time   = origin_zone.local(target_date.year, target_date.month, target_date.day, 9, 0)

        patch :update, params: {
          id:          origin_phantom,
          scope:       :occurrence,
          agenda_item: { name: "Moved Standup", start_at: target_time.to_i },
        }, format: :json

        moved = AgendaItem.find_by(name: "Moved Standup")
        expect(moved).to be_present
        expect(moved.detached_at).to be_present
        expect(moved.agenda_schedule_id).to eq(sched.id) # historical link preserved
        expect(moved.start_at.in_time_zone(origin_zone).to_date).to eq(target_date)

        # Target date: moved row + the schedule's own phantom for that date = 2.
        items = agenda.items_for(target_date)
        expect(items.size).to eq(2)
        phantom_target = items.find(&:phantom?)
        expect(phantom_target).to be_present
        expect(phantom_target.agenda_schedule_id).to eq(sched.id)

        # Origin date: phantom suppressed via excluded_dates; no real row here = 0.
        expect(agenda.items_for(origin_date)).to be_empty
      end

      it "restore puts a detached row back into the recurring cycle" do
        origin_date = Date.current + 30.days
        patch :update, params: {
          id:          phantom_id,
          scope:       :occurrence,
          agenda_item: { name: "Renamed" },
        }, format: :json
        row = AgendaItem.where(name: "Renamed").first
        expect(row).to be_present
        expect(row.original_start_at).to be_present
        expect(sched.reload.excluded?(origin_date)).to be true

        post :restore, params: { id: row.id }, format: :json
        expect(response).to be_successful
        expect(AgendaItem.find_by(id: row.id)).to be_nil
        expect(sched.reload.excluded?(origin_date)).to be false
        phantom = agenda.items_for(origin_date).first
        expect(phantom).to be_present
        expect(phantom).to be_phantom
        expect(phantom.agenda_schedule_id).to eq(sched.id)
      end

      it "series-scope edit updates the schedule directly" do
        patch :update, params: {
          id:          phantom_id,
          scope:       :series,
          agenda_item: { name: "All-future name" },
        }, format: :json
        expect(sched.reload.name).to eq("All-future name")
      end

      # Regression guard for the "all-day toggle doesn't persist on series edits"
      # bug. The schedule's permit-list and the FE's buildSchedulePayload both
      # used to drop `all_day` silently — so a recurring event flipped to
      # all-day kept rendering as a 1-hour event after save. Locking the
      # round-trip here means a future refactor that drops `all_day` from
      # either side will fail loudly.
      it "series-scope edit propagates all_day=true to the schedule + today's already-started row" do
        # Bday is a yearly event whose first occurrence is today at 7pm. The
        # whole regression hinged on `materialize_upcoming!` skipping today's
        # already-started row (it filtered `start_at: now..`), so a series
        # edit landed on the schedule but never touched the materialized
        # row — `all_day` flipped on the schedule but the row kept 7pm /
        # 60min / `all_day: false`. Travel back in time so the test always
        # runs after 7pm regardless of wall-clock.
        zone = ActiveSupport::TimeZone[user.timezone]
        seven_pm_today = zone.local(Date.current.year, Date.current.month, Date.current.day, 19, 0)
        travel_to(seven_pm_today + 30.minutes) do
          event_sched = create(:agenda_schedule, agenda: agenda, name: "Bday", kind: "event",
            start_time: "19:00", duration_minutes: 60, all_day: false,
            recurrence: { "freq" => "yearly" }, starts_on: Date.current)
          materialized = event_sched.agenda_items.first
          expect(materialized).to be_present, "expected today's 7pm row to materialize"
          phantom = "p-#{event_sched.id}-#{Date.current.iso8601}"

          patch :update, params: {
            id:    phantom,
            scope: :series,
            agenda_item: {
              name: "Bday", kind: "event", all_day: true,
              start_at: Time.current.to_i, end_at: (Time.current + 1.day).to_i,
            },
            # Mirrors what the FE's buildSchedulePayload now sends when
            # `all_day: true` — anchored at 00:00 with 1440min so the
            # materialized occurrences are internally consistent.
            agenda_schedule: {
              name: "Bday", kind: "event", all_day: true,
              start_time: "00:00", duration_minutes: 1440,
              recurrence: { freq: "yearly", interval: 1, unit: "year" },
            },
          }, format: :json

          expect(response).to be_successful, "body=#{response.body}"
          expect(event_sched.reload.all_day).to be true
          expect(event_sched.start_time.strftime("%H:%M")).to eq("00:00")
          expect(event_sched.duration_minutes).to eq(1440)
          materialized.reload
          expect(materialized.all_day).to be true
          # Materialized row's start_at lands at 00:00 local — NOT the
          # original 7pm anchor. This is the line that proves the fix.
          expect(materialized.start_at.in_time_zone(user.timezone).strftime("%H:%M")).to eq("00:00")
        end
      end

      it "occurrence-scope delete just pushes to excluded_dates (no row created)" do
        expect {
          delete :destroy, params: { id: phantom_id, scope: :occurrence }
        }.not_to change(AgendaItem, :count)
        expect(sched.reload.excluded?(Date.current + 30.days)).to be true
      end

      it "non-recurring hard destroy broadcasts the display_id so the FE store prunes the gone row" do
        one_off = create(
          :agenda_item, agenda: agenda, kind: :task,
          name: "One-off", start_at: Time.current,
        )
        payloads = []
        allow(MonitorChannel).to receive(:broadcast_to) { |_user, payload| payloads << payload }

        expect { delete :destroy, params: { id: one_off.id } }
          .to change { AgendaItem.exists?(one_off.id) }.from(true).to(false)

        destroy_payload = payloads.find { |p| p[:id] == :agenda }
        expect(destroy_payload).to be_present
        expect(destroy_payload.dig(:data, :destroyed_item_ids)).to eq([one_off.id.to_s])
      end

      it "cancel-only deletes (recurring occurrence) do NOT populate destroyed_item_ids — delta carries them" do
        payloads = []
        allow(MonitorChannel).to receive(:broadcast_to) { |_user, payload| payloads << payload }
        delete :destroy, params: { id: phantom_id, scope: :occurrence }

        payload = payloads.find { |p| p[:id] == :agenda }
        expect(payload.dig(:data, :destroyed_item_ids)).to eq([])
      end

      it "occurrence-scope delete on a DETACHED recurring item soft-cancels + excludes date" do
        # Detached items used to be destroyed; we now soft-cancel (cancelled_at)
        # to match the "deleting an occurrence shouldn't destroy" rule. The
        # excluded_dates push still happens so the schedule rebuilds the
        # phantom only outside the cancelled date.
        sched = create(
          :agenda_schedule, agenda: agenda, kind: :task,
          name: "Garbage Cans In", recurrence: { "freq" => "daily" },
          starts_on: Date.current - 1
        )
        item = sched.agenda_items.create!(
          agenda:      agenda,
          kind:        :task,
          name:        "Garbage Cans In",
          start_at:    Time.current,
          detached_at: Time.current,
        )

        delete :destroy, params: { id: item.id, scope: :occurrence }

        expect(response).to be_successful
        item.reload
        expect(item.cancelled?).to be(true)
        expect(item.cancelled_at).to be_present
        expect(sched.reload.excluded?(item.occurrence_date)).to be true
      end

      it "series-scope delete on a detached recurring item soft-cancels + ends schedule" do
        sched = create(
          :agenda_schedule, agenda: agenda, kind: :task,
          name: "Garbage Cans In", recurrence: { "freq" => "daily" },
          starts_on: Date.current - 1
        )
        item = sched.agenda_items.create!(
          agenda:      agenda,
          kind:        :task,
          name:        "Garbage Cans In",
          start_at:    Time.current,
          detached_at: Time.current,
        )

        delete :destroy, params: { id: item.id, scope: :series }

        expect(response).to be_successful
        item.reload
        expect(item.cancelled?).to be(true)
        expect(item.cancelled_at).to be_present
        expect(sched.reload.until_on).to be <= Date.current
      end

      it "series-scope delete on a future phantom ends the schedule just before that date" do
        target_date = Date.current + 30.days
        delete :destroy, params: { id: phantom_id, scope: :series }
        expect(sched.reload.until_on).to eq(target_date - 1)
      end
    end

    describe "future-scope (this and following) edit on a recurring item" do
      # Uses an event schedule because that's the drag-and-drop entry point
      # on /agenda/grid; the FE only opens the recurring-scope modal for
      # events with a time + duration.
      let!(:event_sched) {
        create(
          :agenda_schedule, agenda: agenda, name: "Standup", kind: :event,
          start_time: "09:00", duration_minutes: 30,
          recurrence: { "freq" => "daily" }, starts_on: Date.current
        )
      }
      let(:zone) { ActiveSupport::TimeZone[user.timezone] || Time.zone }
      let(:cutoff_date) { Date.current + 10.days }
      let(:cutoff_phantom) { "p-#{event_sched.id}-#{cutoff_date.iso8601}" }

      it "truncates the old schedule at cutoff-1 and creates a tail schedule with the new wall-clock" do
        # User dragged the 9am occurrence on cutoff_date down to 11am.
        new_start = zone.local(cutoff_date.year, cutoff_date.month, cutoff_date.day, 11, 0)
        new_end   = new_start + 30.minutes

        expect {
          patch :update, params: {
            id:    cutoff_phantom,
            scope: :future,
            agenda_item: {
              start_at: new_start.to_i,
              end_at:   new_end.to_i,
            },
          }, format: :json
        }.to change { agenda.agenda_schedules.count }.by(1)

        event_sched.reload
        expect(event_sched.until_on).to eq(cutoff_date - 1)

        tail = agenda.agenda_schedules.where.not(id: event_sched.id).order(:created_at).last
        expect(tail.name).to eq("Standup")
        expect(tail.starts_on).to eq(cutoff_date)
        expect(tail.start_time.strftime("%H:%M")).to eq("11:00")
        expect(tail.duration_minutes).to eq(30)
        expect(tail.recurrence_data[:freq].to_s).to eq("daily")
      end

      it "leaves materialized rows before the cutoff untouched and the after_save hook prunes future ones" do
        pre_cutoff_row = event_sched.agenda_items.order(:start_at).first
        expect(pre_cutoff_row).to be_present

        new_start = zone.local(cutoff_date.year, cutoff_date.month, cutoff_date.day, 11, 0)
        patch :update, params: {
          id:    cutoff_phantom,
          scope: :future,
          agenda_item: { start_at: new_start.to_i, end_at: (new_start + 30.minutes).to_i },
        }, format: :json

        # Pre-cutoff row stays exactly as it was — no cancel, no destroy.
        expect(pre_cutoff_row.reload.cancelled_at).to be_nil
        expect(AgendaItem.exists?(pre_cutoff_row.id)).to be true

        # Future rows on the old schedule that no longer match (now past
        # until_on) are pruned by materialize_upcoming!. Nothing left ≥ cutoff
        # that's still attached to the old schedule.
        expect(event_sched.agenda_items.where(start_at: new_start.beginning_of_day..)).to be_empty
      end

      it "shifts a weekly+by_day rule to the new weekday when the drop crosses days" do
        weekly = create(
          :agenda_schedule, agenda: agenda, name: "Game Night", kind: :event,
          start_time: "20:00", duration_minutes: 180,
          recurrence: { "freq" => "weekly", "by_day" => ["fri"] },
          starts_on: Date.current.beginning_of_week(:sunday) + 5, # Friday
        )
        original_fri = weekly.starts_on + 14 # two weeks out, still a Friday
        target_thu = original_fri - 1
        phantom_id = "p-#{weekly.id}-#{original_fri.iso8601}"
        new_start = zone.local(target_thu.year, target_thu.month, target_thu.day, 17, 30)

        patch :update, params: {
          id:    phantom_id,
          scope: :future,
          agenda_item: { start_at: new_start.to_i, end_at: (new_start + 180.minutes).to_i },
        }, format: :json

        weekly.reload
        expect(weekly.until_on).to eq(original_fri - 1)

        tail = agenda.agenda_schedules.where.not(id: weekly.id).order(:created_at).last
        expect(tail.starts_on).to eq(target_thu)
        expect(tail.recurrence_data[:freq].to_s).to eq("weekly")
        expect(tail.recurrence_data[:by_day]).to eq(["thu"])
      end

      it "shifts a monthly by_month_day rule to the new day-of-month" do
        monthly = create(
          :agenda_schedule, agenda: agenda, name: "Rent", kind: :event,
          start_time: "09:00", duration_minutes: 30,
          recurrence: { "freq" => "monthly", "by_month_day" => [21] },
          starts_on: Date.new(Date.current.year, Date.current.month, 21),
        )
        original_21st = monthly.starts_on >> 1 # next month's 21st
        target_22nd = original_21st + 1
        phantom_id = "p-#{monthly.id}-#{original_21st.iso8601}"
        new_start = zone.local(target_22nd.year, target_22nd.month, target_22nd.day, 10, 0)

        patch :update, params: {
          id:    phantom_id,
          scope: :future,
          agenda_item: { start_at: new_start.to_i, end_at: (new_start + 30.minutes).to_i },
        }, format: :json

        tail = agenda.agenda_schedules.where.not(id: monthly.id).order(:created_at).last
        expect(tail.starts_on).to eq(target_22nd)
        expect(tail.recurrence_data[:by_month_day].map(&:to_i)).to eq([22])
      end

      it "reparents detached rows past the cutoff to the tail schedule and excludes their dates so the new pattern doesn't duplicate" do
        # User previously moved one Standup (Day +14, 9am → 2pm) — that
        # detached row is now standalone but still linked to the old
        # schedule's history. The :future drop happens on Day +10 (the new
        # tail starts there). The detached row at Day +14 must:
        #   (a) survive,
        #   (b) get reparented to the new tail,
        #   (c) NOT trigger a duplicate phantom from the new tail on its date.
        detached_date = cutoff_date + 4
        detached_row = event_sched.agenda_items.create!(
          agenda: agenda, kind: :event, name: "Standup",
          start_at: zone.local(detached_date.year, detached_date.month, detached_date.day, 14, 0),
          end_at:   zone.local(detached_date.year, detached_date.month, detached_date.day, 14, 30),
          detached_at: Time.current,
          original_start_at: zone.local(detached_date.year, detached_date.month, detached_date.day, 9, 0),
        )

        new_start = zone.local(cutoff_date.year, cutoff_date.month, cutoff_date.day, 11, 0)
        patch :update, params: {
          id:    cutoff_phantom,
          scope: :future,
          agenda_item: { start_at: new_start.to_i, end_at: (new_start + 30.minutes).to_i },
        }, format: :json

        tail = agenda.agenda_schedules.where.not(id: event_sched.id).order(:created_at).last
        detached_row.reload
        expect(detached_row.agenda_schedule_id).to eq(tail.id)
        expect(detached_row.detached_at).to be_present
        expect(tail.excluded_dates).to include(detached_date)
        # No phantom should be generated for the detached row's date.
        expect(tail.matches?(detached_date)).to be false
      end

      it "shifts a monthly by_set_pos + by_day rule (Nth weekday of month)" do
        nth = create(
          :agenda_schedule, agenda: agenda, name: "Board Meeting", kind: :event,
          start_time: "09:00", duration_minutes: 60,
          recurrence: { "freq" => "monthly", "by_set_pos" => 2, "by_day" => ["tue"] },
          starts_on: Date.current.beginning_of_month, # find next 2nd Tue below
        )
        # Pick an occurrence date that IS a second-Tuesday-of-month.
        second_tue = (Date.new(Date.current.year, Date.current.month, 1)..Date.new(Date.current.year, Date.current.month, 14)).find { |d| d.wday == 2 && ((d.day - 1) / 7) + 1 == 2 } || (Date.current + 7)
        # Move it to the second Wednesday of the SAME month.
        second_wed = second_tue + 1
        phantom_id = "p-#{nth.id}-#{second_tue.iso8601}"
        new_start = zone.local(second_wed.year, second_wed.month, second_wed.day, 10, 0)

        patch :update, params: {
          id:    phantom_id,
          scope: :future,
          agenda_item: { start_at: new_start.to_i, end_at: (new_start + 60.minutes).to_i },
        }, format: :json

        tail = agenda.agenda_schedules.where.not(id: nth.id).order(:created_at).last
        expect(tail.recurrence_data[:by_day]).to eq(["wed"])
        expect(tail.recurrence_data[:by_set_pos].to_i).to eq(((second_wed.day - 1) / 7) + 1)
      end

      it "broadcasts the destroyed detached row's display_id so the FE store can prune it" do
        original_at = zone.local(cutoff_date.year, cutoff_date.month, cutoff_date.day, 9, 0)
        current_at  = zone.local(cutoff_date.year, cutoff_date.month, cutoff_date.day, 14, 0)
        detached = event_sched.agenda_items.create!(
          agenda: agenda, kind: :event, name: "Standup",
          start_at: current_at, end_at: current_at + 30.minutes,
          detached_at: Time.current, original_start_at: original_at,
        )
        new_start = zone.local(cutoff_date.year, cutoff_date.month, cutoff_date.day, 17, 0)

        # Said twice, by the controller and by the destroyed row itself; the
        # series edit fans out its own announcement alongside them.
        allow(MonitorChannel).to receive(:broadcast_to)
        expect(MonitorChannel).to receive(:broadcast_to).with(
          user,
          hash_including(data: hash_including(destroyed_item_ids: include(detached.display_id))),
        ).at_least(:once)

        patch :update, params: {
          id:    detached.id,
          scope: :future,
          agenda_item: { start_at: new_start.to_i, end_at: (new_start + 30.minutes).to_i },
        }, format: :json
      end

      it "splits the series using ORIGINAL_START_AT when the dragged item is a detached row" do
        # A previous "Just this event" drag moved the cutoff_date 9am
        # occurrence to 2pm — the materialized row carries detached_at +
        # original_start_at pointing at the parent's slot. Now the user
        # drags THAT row to 5pm with "this and following": the parent
        # series should still get truncated at the ORIGINAL slot (so
        # future 9am occurrences stop), the tail starts at the new date
        # with the new wall-clock, and the obsolete detached row is
        # destroyed (subsumed by the tail's fresh first-occurrence).
        original_at = zone.local(cutoff_date.year, cutoff_date.month, cutoff_date.day, 9, 0)
        current_at  = zone.local(cutoff_date.year, cutoff_date.month, cutoff_date.day, 14, 0)
        detached = event_sched.agenda_items.create!(
          agenda: agenda, kind: :event, name: "Standup",
          start_at: current_at, end_at: current_at + 30.minutes,
          detached_at: Time.current, original_start_at: original_at,
        )
        new_start = zone.local(cutoff_date.year, cutoff_date.month, cutoff_date.day, 17, 0)

        expect {
          patch :update, params: {
            id:    detached.id,
            scope: :future,
            agenda_item: { start_at: new_start.to_i, end_at: (new_start + 30.minutes).to_i },
          }, format: :json
        }.to change { agenda.agenda_schedules.count }.by(1)

        # Parent truncated at the day BEFORE the detached row's ORIGINAL
        # slot (not its current Saturday landing), so future regular
        # occurrences stop there.
        event_sched.reload
        expect(event_sched.until_on).to eq(cutoff_date - 1)

        # Tail picks up at the new wall-clock.
        tail = agenda.agenda_schedules.where.not(id: event_sched.id).order(:created_at).last
        expect(tail.start_time.strftime("%H:%M")).to eq("17:00")
        expect(tail.starts_on).to eq(cutoff_date)

        # The detached row is gone — replaced by the tail's fresh
        # first-occurrence row.
        expect(AgendaItem.exists?(detached.id)).to be false
      end

      it "splits a monthly Nth-weekday series via a detached row drag (Game Night scenario)" do
        # User's exact recurrence shape from the screenshots: "the first
        # Friday of every month at 9:30pm." First detach Fri → Sat (just
        # this event), then drag the detached Sat → Thu (this and
        # following). Both rules need to be rewritten so future first-
        # Fridays stop and future first-Thursdays start.
        first_friday_of_month = (Date.current.beginning_of_month..Date.current.end_of_month).find { |d| d.wday == 5 } || Date.current.next_occurring(:friday)
        monthly = create(
          :agenda_schedule, agenda: agenda, name: "Game Night", kind: :event,
          start_time: "21:30", duration_minutes: 180,
          recurrence: { "freq" => "monthly", "by_set_pos" => 1, "by_day" => ["fri"] },
          starts_on: first_friday_of_month,
        )

        # Detach next month's first Friday → next-day Saturday.
        target_friday = (first_friday_of_month >> 1).beginning_of_month
        target_friday += ((5 - target_friday.wday) % 7) # roll to that month's first Friday
        target_saturday = target_friday + 1
        detached = monthly.agenda_items.create!(
          agenda: agenda, kind: :event, name: "Game Night",
          start_at: zone.local(target_saturday.year, target_saturday.month, target_saturday.day, 21, 30),
          end_at:   zone.local(target_saturday.year, target_saturday.month, target_saturday.day, 21, 30) + 180.minutes,
          detached_at: Time.current,
          original_start_at: zone.local(target_friday.year, target_friday.month, target_friday.day, 21, 30),
        )
        monthly.add_excluded_date!(target_friday)

        # Drag detached Sat → Thu (= target_friday - 1, which is in the SAME
        # week so still the first Thursday of that month).
        target_thursday = target_friday - 1
        thu_start = zone.local(target_thursday.year, target_thursday.month, target_thursday.day, 16, 15)
        patch :update, params: {
          id:    detached.id,
          scope: :future,
          agenda_item: { start_at: thu_start.to_i, end_at: (thu_start + 180.minutes).to_i },
        }, format: :json

        # Parent truncated, detached destroyed.
        monthly.reload
        expect(monthly.until_on).to eq(target_friday - 1)
        expect(AgendaItem.exists?(detached.id)).to be false

        # Tail is "first Thursday of every month" at the new wall-clock.
        tail = agenda.agenda_schedules.where.not(id: monthly.id).order(:created_at).last
        expect(tail.recurrence_data[:freq].to_s).to eq("monthly")
        expect(tail.recurrence_data[:by_day]).to eq(["thu"])
        expect(tail.recurrence_data[:by_set_pos].to_i).to eq(1)
        expect(tail.starts_on).to eq(target_thursday)
        expect(tail.start_time.strftime("%H:%M")).to eq("16:15")

        # Sanity: tail matches the NEXT first Thursday, not first Friday.
        next_month_first = (target_friday >> 1).beginning_of_month
        next_first_thu = next_month_first + ((4 - next_month_first.wday) % 7)
        next_first_fri = next_month_first + ((5 - next_month_first.wday) % 7)
        expect(tail.matches?(next_first_thu)).to be true
        expect(tail.matches?(next_first_fri)).to be false
        # Parent does NOT match anything future.
        expect(monthly.matches?(next_first_fri)).to be false
      end

      it "supports a second future-scope split AFTER an earlier detach+future-split (real user flow)" do
        # Step 1: weekly Friday Game Night.
        friday = Date.current.beginning_of_week(:sunday) + 5
        weekly = create(
          :agenda_schedule, agenda: agenda, name: "Game Night", kind: :event,
          start_time: "21:30", duration_minutes: 180,
          recurrence: { "freq" => "weekly", "by_day" => ["fri"] },
          starts_on: friday,
        )
        target_friday = friday + 14
        target_saturday = target_friday + 1

        # Step 2: "Just this event" moves target Friday → Saturday → detached row.
        detached = weekly.agenda_items.create!(
          agenda: agenda, kind: :event, name: "Game Night",
          start_at: zone.local(target_saturday.year, target_saturday.month, target_saturday.day, 21, 30),
          end_at:   zone.local(target_saturday.year, target_saturday.month, target_saturday.day, 21, 30) + 180.minutes,
          detached_at: Time.current,
          original_start_at: zone.local(target_friday.year, target_friday.month, target_friday.day, 21, 30),
        )
        weekly.add_excluded_date!(target_friday)

        # Step 3: "This and following" from the detached row → Thursday at new time.
        target_thursday = target_friday - 1
        thu_start = zone.local(target_thursday.year, target_thursday.month, target_thursday.day, 16, 15)
        patch :update, params: {
          id:    detached.id,
          scope: :future,
          agenda_item: { start_at: thu_start.to_i, end_at: (thu_start + 180.minutes).to_i },
        }, format: :json

        # Verify: parent truncated, detached gone, tail on Thursdays.
        weekly.reload
        expect(weekly.until_on).to eq(target_friday - 1)
        expect(AgendaItem.exists?(detached.id)).to be false
        tail = agenda.agenda_schedules.where.not(id: weekly.id).order(:created_at).last
        expect(tail.recurrence_data[:by_day]).to eq(["thu"])
        expect(tail.starts_on).to eq(target_thursday)
        expect(tail.start_time.strftime("%H:%M")).to eq("16:15")

        # Step 4: drag a FURTHER tail row to a different day, "this and following" again.
        next_thu = target_thursday + 7
        next_phantom = "p-#{tail.id}-#{next_thu.iso8601}"
        target_monday = next_thu + 4 # Mon (skipping Fri/Sat/Sun ahead)
        mon_start = zone.local(target_monday.year, target_monday.month, target_monday.day, 14, 0)

        patch :update, params: {
          id:    next_phantom,
          scope: :future,
          agenda_item: { start_at: mon_start.to_i, end_at: (mon_start + 180.minutes).to_i },
        }, format: :json

        # Verify: tail truncated, tail2 on Mondays.
        tail.reload
        expect(tail.until_on).to eq(next_thu - 1)
        tail2 = agenda.agenda_schedules.where.not(id: [weekly.id, tail.id]).order(:created_at).last
        expect(tail2.recurrence_data[:by_day]).to eq(["mon"])
        expect(tail2.starts_on).to eq(target_monday)
        expect(tail2.start_time.strftime("%H:%M")).to eq("14:00")
      end

      it "still falls back to occurrence-only when the parent is already truncated past the detached row's original date" do
        # The parent series was already split previously — until_on is
        # BEFORE this detached row's original slot. "And following"
        # against a dead series has no future to walk forward, so we
        # gracefully degrade to a plain occurrence update.
        original_at = zone.local(cutoff_date.year, cutoff_date.month, cutoff_date.day, 9, 0)
        detached = event_sched.agenda_items.create!(
          agenda: agenda, kind: :event, name: "Standup",
          start_at: original_at + 5.hours, end_at: original_at + 5.hours + 30.minutes,
          detached_at: Time.current, original_start_at: original_at,
        )
        event_sched.update!(until_on: cutoff_date - 5)
        new_start = original_at + 10.hours

        expect {
          patch :update, params: {
            id:    detached.id,
            scope: :future,
            agenda_item: { start_at: new_start.to_i, end_at: (new_start + 30.minutes).to_i },
          }, format: :json
        }.not_to change { agenda.agenda_schedules.count }

        # Detached row moved to the new time (occurrence-only behavior).
        detached.reload
        expect(detached.start_at.to_i).to eq(new_start.to_i)
      end
    end
  end

  # Covers the RSVP path: PATCH/POST /agenda_items/:id/respond, which mirrors
  # the connected account's responseStatus to Google via events.patch and
  # then writes self_response + the updated attendees array back to local
  # metadata.
  describe "responding to an item" do
    let(:user) { create(:user) }
    let(:google_account) {
      GoogleAccount.create!(user: user, email: "me@example.com", access_token: "t", refresh_token: "r")
    }
    let(:gcal_agenda) {
      create(:agenda, user: user, source: :google, external_id: "cal-rsvp",
             google_account: google_account)
    }
    let(:local_agenda) { create(:agenda, user: user) }
    let(:api) { instance_double(Oauth::GoogleApi) }

    before do
      allow(Oauth::GoogleApi).to receive(:for_account).and_return(api)
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
      allow_any_instance_of(ApplicationController).to receive(:user_signed_in?).and_return(true)
      allow_any_instance_of(ApplicationController).to receive(:authorize_user_or_guest).and_return(true)
    end

    let!(:item) {
      gcal_agenda.agenda_items.create!(
        kind:         :event,
        name:         "Invite",
        start_at:     1.hour.from_now,
        end_at:       2.hours.from_now,
        external_uid: "uid-rsvp-1",
        metadata:     {
          "attendees"     => [
            { "email" => "me@example.com", "self" => true, "response_status" => "needsAction" },
            { "email" => "boss@example.com", "response_status" => "accepted" },
          ],
          "organizer"     => { "email" => "boss@example.com" },
          "self_response" => "needsAction",
        }
      )
    }

    it "mirrors an accept to Google with the updated attendees list" do
      expect(api).to receive(:patch_event) do |cal_id, evt_id, body|
        expect(cal_id).to eq("cal-rsvp")
        expect(evt_id).to eq("uid-rsvp-1")
        self_attendee = body[:attendees].find { |a| a[:email] == "me@example.com" }
        expect(self_attendee[:responseStatus]).to eq("accepted")
        { etag: %("e1") }
      end

      post :respond, params: { id: item.id, response: "accepted" }, format: :json
      expect(response).to have_http_status(:ok)
      expect(item.reload.self_response).to eq("accepted")
      expect(item.status).to eq("confirmed")
    end

    it "flips status to :tentative on a tentative response" do
      allow(api).to receive(:patch_event).and_return({})
      post :respond, params: { id: item.id, response: "tentative" }, format: :json
      expect(item.reload.status).to eq("tentative")
      expect(item.self_response).to eq("tentative")
    end

    it "stores declined without flipping to :cancelled (so the row stays visible)" do
      allow(api).to receive(:patch_event).and_return({})
      post :respond, params: { id: item.id, response: "declined" }, format: :json
      expect(item.reload.declined?).to be true
      expect(item.status).to eq("confirmed")
    end

    it "rejects unknown response values" do
      post :respond, params: { id: item.id, response: "snoozed" }, format: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "refuses RSVPs on local (non-Google) agendas" do
      local_item = local_agenda.agenda_items.create!(
        kind: :event, name: "Local", start_at: 1.hour.from_now, end_at: 2.hours.from_now,
      )
      post :respond, params: { id: local_item.id, response: "accepted" }, format: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "search" do
    let(:user) { create(:user) }
    let!(:agenda) { create(:agenda, user: user) }

    before { sign_in user }

    describe "GET #search" do
      it "returns matches scoped to the user's accessible agendas" do
        match = create(:agenda_item, agenda: agenda, name: "Dentist visit",
          kind: :task, start_at: 2.months.ago)
        _other = create(:agenda_item, agenda: agenda, name: "Grocery run",
          kind: :task, start_at: 2.months.ago)

        get :search, params: { q: "dentist" }, format: :json
        expect(response).to be_successful
        body = JSON.parse(response.body)
        ids = body["items"].map { |i| i["id"] }
        expect(ids).to include(match.id.to_s)
        expect(ids).not_to include(_other.id.to_s)
      end

      it "excludes items owned by other users" do
        other_user = create(:user)
        other_agenda = create(:agenda, user: other_user)
        create(:agenda_item, agenda: other_agenda, name: "Dentist visit",
          kind: :task, start_at: 2.months.ago)

        get :search, params: { q: "dentist" }, format: :json
        body = JSON.parse(response.body)
        expect(body["items"]).to be_empty
      end

      it "filters to items before the `before` parameter" do
        past = create(:agenda_item, agenda: agenda, name: "Dentist old",
          kind: :task, start_at: 60.days.ago)
        recent = create(:agenda_item, agenda: agenda, name: "Dentist recent",
          kind: :task, start_at: 5.days.ago)

        get :search, params: { q: "dentist", before: 30.days.ago.iso8601 }, format: :json
        body = JSON.parse(response.body)
        ids = body["items"].map { |i| i["id"] }
        expect(ids).to include(past.id.to_s)
        expect(ids).not_to include(recent.id.to_s)
      end

      it "returns empty when q is blank" do
        create(:agenda_item, agenda: agenda, name: "Dentist", kind: :task, start_at: 1.day.ago)
        get :search, params: { q: "" }, format: :json
        body = JSON.parse(response.body)
        expect(body["items"]).to eq([])
      end

      it "supports is: tokens" do
        completed = create(:agenda_item, agenda: agenda, name: "Refi paperwork",
          kind: :task, start_at: 10.days.ago, completed_at: 9.days.ago)
        _incomplete = create(:agenda_item, agenda: agenda, name: "Refi followup",
          kind: :task, start_at: 10.days.ago)

        get :search, params: { q: "refi is:completed" }, format: :json
        body = JSON.parse(response.body)
        ids = body["items"].map { |i| i["id"] }
        expect(ids).to eq([completed.id.to_s])
      end

      # The search modal reads `editable` off each hit to decide whether the
      # details modal offers Edit / Follow up. Store-sourced hits get it from
      # the aggregate payload; these have to answer the same.
      it "stamps editable on each hit" do
        own = create(:agenda_item, agenda: agenda, name: "Dentist mine",
          kind: :task, start_at: 2.months.ago)
        viewer_agenda = create(:agenda, user: create(:user))
        AgendaShare.create!(agenda: viewer_agenda, user: user, permission: :viewer)
        readonly = create(:agenda_item, agenda: viewer_agenda, name: "Dentist theirs",
          kind: :task, start_at: 2.months.ago)

        get :search, params: { q: "dentist" }, format: :json
        body = JSON.parse(response.body)
        flags = body["items"].to_h { |i| [i["id"], i["editable"]] }
        expect(flags[own.id.to_s]).to eq(true)
        expect(flags[readonly.id.to_s]).to eq(false)
      end
    end
  end

  # Round-2 audit followups for AgendaItemsController. Cover the new
  # behaviors that came out of the audit-followup pass:
  #   * Mirror-first ordering — Google failures leave the local row untouched.
  #   * Cross-source recurring move cancels the upstream occurrence (uses
  #     mirror_occurrence_cancel_to_google! rather than mirror_destroy).
  #   * Bad-Gateway error JSON when Google rejects a write.
  #   * Series-update RRULE push to Google when explicit schedule payload.
  describe "google sync errors" do
    let(:user) { create(:user) }
    let(:google_account) {
      GoogleAccount.create!(user: user, email: "rt@example.com", access_token: "t", refresh_token: "r")
    }
    let(:gcal_agenda) {
      create(:agenda, user: user, source: :google, external_id: "cal-rt",
             google_account: google_account)
    }
    let(:local_agenda) { create(:agenda, user: user) }
    let(:api) { instance_double(Oauth::GoogleApi) }

    before do
      allow(Oauth::GoogleApi).to receive(:for_account).and_return(api)
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
      allow_any_instance_of(ApplicationController).to receive(:user_signed_in?).and_return(true)
      allow_any_instance_of(ApplicationController).to receive(:authorize_user_or_guest).and_return(true)
    end

    def google_error(code)
      response = instance_double(RestClient::Response, code: code, body: "{}", request: nil)
      klass = {
        403 => RestClient::Forbidden,
        404 => RestClient::NotFound,
        429 => RestClient::TooManyRequests,
      }[code] || RestClient::BadRequest
      klass.new(response)
    end

    describe "mirror-first ordering on update" do
      let!(:item) {
        gcal_agenda.agenda_items.create!(
          kind: :event, name: "From sync", start_at: 1.hour.from_now,
          end_at: 2.hours.from_now, external_uid: "uid-mf-1", external_etag: %("e0")
        )
      }

      it "leaves the local row untouched when Google PATCH is rejected, and returns 502 with the reason" do
        allow(api).to receive(:patch_event).and_raise(google_error(403))

        patch :update, params: {
          id:          item.id,
          agenda_item: { name: "Renamed" },
        }, format: :json

        expect(response).to have_http_status(:bad_gateway)
        body = JSON.parse(response.body)
        expect(body["errors"].first).to match(/permission/i)
        expect(item.reload.name).to eq("From sync") # local intact
      end

      it "captures the response etag + updated when Google accepts the PATCH" do
        allow(api).to receive(:patch_event).and_return({
          etag:    %("etag-new"),
          updated: "2026-05-23T12:00:00Z",
        })

        patch :update, params: {
          id:          item.id,
          agenda_item: { name: "Renamed" },
        }, format: :json

        expect(response).to be_successful
        expect(item.reload.name).to eq("Renamed")
        expect(item.external_etag).to eq(%("etag-new"))
      end
    end

    describe "non-recurring delete with Google rejection" do
      let!(:item) {
        gcal_agenda.agenda_items.create!(
          kind: :event, name: "Synced", start_at: 1.hour.from_now,
          end_at: 2.hours.from_now, external_uid: "uid-d-1"
        )
      }

      it "doesn't destroy the local row when Google delete fails (non-NotFound)" do
        allow(api).to receive(:delete_event).and_raise(google_error(403))

        delete :destroy, params: { id: item.id }, format: :json

        expect(response).to have_http_status(:bad_gateway)
        expect(AgendaItem.exists?(item.id)).to be(true)
      end

      it "treats 404 from Google as success (already gone upstream)" do
        allow(api).to receive(:delete_event).and_raise(google_error(404))

        delete :destroy, params: { id: item.id }, format: :json

        expect(response).to have_http_status(:no_content)
        expect(AgendaItem.exists?(item.id)).to be(false)
      end
    end

    describe "cross-source recurring move from Google → local" do
      let(:sched) {
        gcal_agenda.agenda_schedules.create!(
          kind:             :event,
          name:             "Standup",
          start_time:       "09:00",
          starts_on:        Date.current - 7,
          duration_minutes: 30,
          recurrence:       { freq: "daily" },
          external_uid:     "evt-series-1",
        )
      }
      let!(:item) {
        gcal_agenda.agenda_items.create!(
          kind:               :event,
          name:               "Standup",
          agenda_schedule:    sched,
          start_at:           Time.zone.local(Date.current.year, Date.current.month, Date.current.day, 9, 0),
          end_at:             Time.zone.local(Date.current.year, Date.current.month, Date.current.day, 9, 30),
          external_uid:       "evt-series-1_inst-1",
        )
      }

      it "cancels the specific occurrence upstream via patch_event(status: cancelled)" do
        expect(api).to receive(:patch_event).with(
          gcal_agenda.external_id,
          "evt-series-1_inst-1",
          { status: "cancelled" },
        )

        patch :update, params: {
          id:          item.id,
          scope:       "occurrence",
          agenda_item: { agenda_id: local_agenda.id, name: "Standup" },
        }, format: :json

        expect(response).to be_successful
        expect(item.reload.agenda_id).to eq(local_agenda.id)
        expect(item.external_uid).to be_nil
      end

      it "uses list_event_instances to resolve a phantom occurrence id when external_uid is blank" do
        # Drop the materialized row so the phantom path runs.
        item.destroy
        phantom_date = Date.current
        allow(api).to receive(:list_event_instances).and_return({
          items: [{ id: "evt-series-1_RESOLVED", originalStartTime: { dateTime: phantom_date.iso8601 + "T09:00:00Z" } }],
        })
        expect(api).to receive(:patch_event).with(
          gcal_agenda.external_id,
          "evt-series-1_RESOLVED",
          { status: "cancelled" },
        )

        patch :update, params: {
          id:          "p-#{sched.id}-#{phantom_date.iso8601}",
          scope:       "occurrence",
          agenda_item: { agenda_id: local_agenda.id, name: "Standup" },
        }, format: :json

        expect(response).to be_successful
      end
    end

    describe "series update pushes RRULE upstream" do
      let(:sched) {
        gcal_agenda.agenda_schedules.create!(
          kind:             :event,
          name:             "Standup",
          start_time:       "09:00",
          starts_on:        Date.current,
          duration_minutes: 30,
          recurrence:       { freq: "weekly", by_day: %w[mon wed fri] },
          external_uid:     "evt-series-rrule",
        )
      }
      let!(:item) {
        gcal_agenda.agenda_items.create!(
          kind:               :event,
          name:               "Standup",
          agenda_schedule:    sched,
          start_at:           Time.zone.local(Date.current.year, Date.current.month, Date.current.day, 9, 0),
          end_at:             Time.zone.local(Date.current.year, Date.current.month, Date.current.day, 9, 30),
          external_uid:       "evt-series-rrule_inst-1",
        )
      }

      it "includes a serialized RRULE in the patch_event body when the schedule payload changes recurrence" do
        received_body = nil
        allow(api).to receive(:patch_event) { |_cal, _id, body|
          received_body = body
          { etag: %("e-new"), updated: "2026-05-23T12:00:00Z" }
        }

        patch :update, params: {
          id:              item.id,
          scope:           "series",
          agenda_item:     { name: "Standup" },
          agenda_schedule: {
            name:       "Standup",
            kind:       :event,
            start_time: "09:00",
            starts_on:  sched.starts_on.iso8601,
            recurrence: { freq: "weekly", by_day: %w[mon tue wed] },
          },
        }, format: :json

        expect(response).to be_successful
        expect(received_body[:recurrence]).to be_present
        expect(received_body[:recurrence].first).to match(/FREQ=WEEKLY/)
      end
    end
  end
end
