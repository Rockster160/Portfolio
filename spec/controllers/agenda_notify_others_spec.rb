require "rails_helper"

# The "Notify others" opt-in: a checked box on a SHARED agenda enqueues the
# cross-user Buddy briefing after a successful save; unchecked / absent, or a
# solo agenda, never does.
RSpec.describe "Agenda 'Notify others' opt-in" do
  let(:user)    { create(:user) }
  let(:partner) { create(:user) }

  before { ByteConversation.create!(user: partner, mode: :buddy, name: "Buddy") }

  describe AgendaItemsController, type: :controller do
    let!(:shared) { create(:agenda, user: user) }
    let!(:solo)   { create(:agenda, user: user) }

    before do
      sign_in user
      AgendaShare.create!(agenda: shared, user: partner, permission: :editor)
    end

    def create_item(agenda, notify:)
      post :create, params: {
        agenda_item: {
          agenda_id:     agenda.id,
          name:          "Coffee",
          kind:          "event",
          start_at:      Time.current.to_i,
          end_at:        (1.hour.from_now).to_i,
          notify_others: notify,
        },
      }, format: :json
    end

    it "enqueues the briefing when checked on a shared agenda" do
      expect(AgendaNotifyOthersWorker).to receive(:perform_in).with(
        instance_of(ActiveSupport::Duration), "AgendaItem", instance_of(Integer), user.id, "created"
      )
      create_item(shared, notify: true)
      expect(response).to have_http_status(:ok)
    end

    it "does not enqueue when unchecked" do
      expect(AgendaNotifyOthersWorker).not_to receive(:perform_in)
      create_item(shared, notify: false)
    end

    it "does not enqueue when the flag is absent" do
      expect(AgendaNotifyOthersWorker).not_to receive(:perform_in)
      post :create, params: {
        agenda_item: {
          agenda_id: shared.id,
          name:      "Coffee",
          kind:      "event",
          start_at:  Time.current.to_i,
          end_at:    (1.hour.from_now).to_i,
        },
      }, format: :json
    end

    it "does not enqueue on a solo (unshared) agenda even when checked" do
      expect(AgendaNotifyOthersWorker).not_to receive(:perform_in)
      create_item(solo, notify: true)
    end

    it "enqueues with 'updated' on a successful edit" do
      item = create(
        :agenda_item, agenda: shared, kind: :event,
        start_at: Time.current, end_at: 1.hour.from_now, name: "Coffee"
      )
      expect(AgendaNotifyOthersWorker).to receive(:perform_in).with(
        anything, "AgendaItem", item.id, user.id, "updated"
      )
      patch :update, params: {
        id:          item.id,
        agenda_item: { name: "Coffee w/ Sam", notify_others: true },
      }, format: :json
    end
  end

  describe AgendaSchedulesController, type: :controller do
    let!(:shared) { create(:agenda, user: user) }

    before do
      sign_in user
      AgendaShare.create!(agenda: shared, user: partner, permission: :editor)
    end

    it "enqueues an AgendaSchedule briefing when checked on a shared agenda" do
      expect(AgendaNotifyOthersWorker).to receive(:perform_in).with(
        anything, "AgendaSchedule", instance_of(Integer), user.id, "created"
      )
      post :create, params: {
        agenda_schedule: {
          agenda_id:     shared.id,
          name:          "Standup",
          kind:          "task",
          start_time:    "09:00",
          starts_on:     Date.current.iso8601,
          recurrence:    { freq: "daily" },
          notify_others: true,
        },
      }, format: :json
      expect(response).to have_http_status(:ok)
    end
  end
end
