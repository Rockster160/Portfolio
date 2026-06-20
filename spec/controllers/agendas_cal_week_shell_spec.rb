require "rails_helper"

# Phase-2 shell guard: /agenda/cal/week MUST render an empty data-free
# shell. The AgendaStore hydrates events client-side from
# /agenda/sync/bootstrap; server-rendered seeds (the slow path that
# made next-week navigation feel laggy) belong to the old pipeline and
# stay out of this view forever.
RSpec.describe AgendasController, type: :controller do
  render_views

  let(:user)   { create(:user) }
  let!(:agenda) { create(:agenda, user: user) }

  before { sign_in user }

  describe "GET #cal_week" do
    it "renders the shell with no event seeds even when items exist" do
      now = ActiveSupport::TimeZone[user.timezone].now.beginning_of_day
      create(:agenda_item, agenda: agenda, kind: :task, start_at: now + 10.hours, name: "INSIDE WINDOW")
      create(
        :agenda_item, agenda: agenda, kind: :event,
        start_at: now + 11.hours, end_at: now + 12.hours, name: "SOLID EVENT"
      )

      get :cal_week
      expect(response).to be_successful
      expect(response.body).to include("cal-week-seeds")
      # Server must not emit any item data. The seeds container is an
      # empty marker; events are hydrated by the FE from AgendaStore.
      expect(response.body).not_to match(/cal-week-seed\s+agenda-item-data/)
      expect(response.body).not_to include("INSIDE WINDOW")
      expect(response.body).not_to include("SOLID EVENT")
      # Cold-start centered overlay was removed (per never-block-user rule).
      # Empty grid speaks for itself; agenda-pending-badge handles subtle sync state.
      expect(response.body).not_to include("data-cold-start")
    end

    it "still renders the toolbar + week scaffold for the requested date" do
      get :cal_week, params: { date: "2026-07-15" }
      expect(response.body).to include("cal-week-grid")
      expect(response.body).to include("data-week-start=\"2026-07-13\"") # Mon
      expect(response.body).to include("data-week-end=\"2026-07-19\"")
    end
  end
end
