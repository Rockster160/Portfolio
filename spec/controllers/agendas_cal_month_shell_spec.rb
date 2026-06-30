require "rails_helper"

# Mirrors agendas_cal_week_shell_spec — guards the /agenda/month shell
# stays a data-free scaffold. The cell-fillers live in JS
# (month_view.js + agenda_cal.js) and pull from AgendaStore.
#
# Also pins the multi-month structure the mobile infinite-scroll layer
# depends on: `[data-month-stack]` wraps a single `[data-month-block]`
# bracketed by up/down `[data-month-loader]` sentinels.
RSpec.describe AgendasController, type: :controller do
  render_views

  let(:user)   { create(:user) }
  let!(:agenda) { create(:agenda, user: user) }

  before { sign_in user }

  describe "GET #cal_month" do
    it "renders the shell scoped to the requested month" do
      get :cal_month, params: { month: "2026-07" }

      expect(response).to be_successful
      expect(response.body).to include("cal-month-grid")
      expect(response.body).to include("data-month-start=\"2026-06-29\"") # Mon of week containing Jul 1
      expect(response.body).to include("data-month-end=\"2026-08-02\"")   # Sun of week containing Jul 31
    end

    it "wraps the single month block in the infinite-scroll scaffold" do
      get :cal_month, params: { month: "2026-07" }

      # Stack + month-block carry the data hooks the JS layer reads.
      expect(response.body).to include("data-month-stack")
      expect(response.body).to include("data-month-block")
      expect(response.body).to include("data-month-iso=\"2026-07\"")
      # Both sentinels render so the IntersectionObserver has something
      # to bind to the moment the mobile layer activates.
      expect(response.body).to include('data-month-loader="up"')
      expect(response.body).to include('data-month-loader="down"')
      # Inline block header is present (display:none on desktop, visible
      # on mobile) — drives the iOS-style "June 2026" between blocks.
      expect(response.body).to include("data-block-header")
    end

    it "emits no item data in the shell even when items exist" do
      now = ActiveSupport::TimeZone[user.timezone].now.beginning_of_day
      create(:agenda_item, agenda: agenda, kind: :event,
        start_at: now + 11.hours, end_at: now + 12.hours, name: "SHELL-LEAK CHECK")

      get :cal_month
      expect(response).to be_successful
      expect(response.body).not_to include("SHELL-LEAK CHECK")
    end
  end
end
