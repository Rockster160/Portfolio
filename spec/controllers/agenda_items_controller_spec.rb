require "rails_helper"

RSpec.describe AgendaItemsController, type: :controller do
  let(:user) { create(:user) }
  let!(:agenda) { create(:agenda, user: user) }

  before { sign_in user }

  describe "PATCH #update with location/notes (regression)" do
    let!(:item) {
      create(:agenda_item, agenda: agenda, kind: :task, name: "Task",
        start_at: Time.current, location: "", notes: "")
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
      sched = create(:agenda_schedule, agenda: agenda, kind: :task, name: "Daily",
        start_time: "09:00", recurrence: { "freq" => "daily" }, starts_on: Date.current)
      occ = sched.agenda_items.create!(agenda: agenda, kind: :task, name: "Daily",
        start_at: Time.current, detached_at: Time.current)
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
      sched = create(:agenda_schedule, agenda: agenda, kind: :task, name: "Daily",
        start_time: "09:00", recurrence: { "freq" => "daily" }, starts_on: Date.current)
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
      sched = create(:agenda_schedule, agenda: agenda, kind: :task, name: "Daily",
        start_time: "09:00", recurrence: { "freq" => "daily" }, starts_on: Date.current)
      phantom_id = "p-#{sched.id}-#{(Date.current + 5.days).iso8601}"
      patch :update, params: {
        id:               phantom_id,
        scope:            :series,
        agenda_item:      { agenda_id: agenda.id, name: "Daily", location: "HQ", notes: "All-hands" },
        agenda_schedule:  {
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

  describe "POST #create" do
    it "creates a one-off task and broadcasts" do
      expect(MonitorChannel).to receive(:broadcast_to).with(user, hash_including(id: :agenda))
      expect {
        post :create, params: {
          agenda_item: { agenda_id: agenda.id, name: "Walk dog", kind: "task", start_at: Time.current.iso8601 },
        }, format: :json
      }.to change { agenda.agenda_items.count }.by(1)
    end

    it "returns 404 when the target agenda isn't accessible" do
      other_user = create(:user, phone: "5559876543")
      other = create(:agenda, user: other_user)
      post :create, params: {
        agenda_item: { agenda_id: other.id, name: "Sneaky", kind: "task", start_at: Time.current.iso8601 },
      }, format: :json
      expect(response).to have_http_status(:not_found)
    end

    it "creates into a shared agenda when the user is an editor" do
      other_user = create(:user, phone: "5559876543")
      shared = create(:agenda, user: other_user)
      AgendaShare.create!(agenda: shared, user: user, permission: :editor)
      expect {
        post :create, params: {
          agenda_item: { agenda_id: shared.id, name: "Team task", kind: "task", start_at: Time.current.iso8601 },
        }, format: :json
      }.to change { shared.agenda_items.count }.by(1)
    end

    it "rejects creation on a viewer-only shared agenda" do
      other_user = create(:user, phone: "5559876543")
      shared = create(:agenda, user: other_user)
      AgendaShare.create!(agenda: shared, user: user, permission: :viewer)
      post :create, params: {
        agenda_item: { agenda_id: shared.id, name: "Hands-off", kind: "task", start_at: Time.current.iso8601 },
      }, format: :json
      expect(response).to have_http_status(:not_found)
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
      ids = move_payload[:data][:changed].map { |c| c[:agenda_id] }
      expect(ids).to contain_exactly(agenda.id, other.id)
    end
  end

  describe "phantom interactions" do
    let(:sched) {
      create(:agenda_schedule, agenda: agenda, name: "Standup", kind: "task",
        start_time: "09:00", recurrence: { "freq" => "daily" }, starts_on: Date.current)
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

    it "series-scope edit updates the schedule directly" do
      patch :update, params: {
        id:          phantom_id,
        scope:       :series,
        agenda_item: { name: "All-future name" },
      }, format: :json
      expect(sched.reload.name).to eq("All-future name")
    end

    it "occurrence-scope delete just pushes to excluded_dates (no row created)" do
      expect {
        delete :destroy, params: { id: phantom_id, scope: :occurrence }
      }.not_to change(AgendaItem, :count)
      expect(sched.reload.excluded?(Date.current + 30.days)).to be true
    end

    it "occurrence-scope delete on a DETACHED recurring item actually destroys the row" do
      sched = create(:agenda_schedule, agenda: agenda, kind: :task,
        name: "Garbage Cans In", recurrence: { "freq" => "daily" },
        starts_on: Date.current - 1)
      item = sched.agenda_items.create!(
        agenda:      agenda,
        kind:        :task,
        name:        "Garbage Cans In",
        start_at:    Time.current,
        detached_at: Time.current,
      )

      delete :destroy, params: { id: item.id, scope: :occurrence }

      expect(response).to be_successful
      expect(AgendaItem.find_by(id: item.id)).to be_nil
      expect(sched.reload.excluded?(item.occurrence_date)).to be true
    end

    it "series-scope delete on a detached recurring item actually destroys + ends schedule" do
      sched = create(:agenda_schedule, agenda: agenda, kind: :task,
        name: "Garbage Cans In", recurrence: { "freq" => "daily" },
        starts_on: Date.current - 1)
      item = sched.agenda_items.create!(
        agenda:      agenda,
        kind:        :task,
        name:        "Garbage Cans In",
        start_at:    Time.current,
        detached_at: Time.current,
      )

      delete :destroy, params: { id: item.id, scope: :series }

      expect(response).to be_successful
      expect(AgendaItem.find_by(id: item.id)).to be_nil
      expect(sched.reload.until_on).to be <= Date.current
    end

    it "series-scope delete on a future phantom ends the schedule just before that date" do
      target_date = Date.current + 30.days
      delete :destroy, params: { id: phantom_id, scope: :series }
      expect(sched.reload.until_on).to eq(target_date - 1)
    end
  end
end
