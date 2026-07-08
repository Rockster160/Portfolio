require "rails_helper"

# Structural smoke — pins the selectors the search modal controller
# (`app/javascript/src/agenda/search.js`) queries against. Rendered via
# the day-view controller so `render_modal`'s layout+block wiring runs
# the same way it does in the browser.
RSpec.describe AgendasController, type: :controller do
  render_views

  let(:user) { create(:user) }
  let!(:agenda) { create(:agenda, user: user) }
  before { sign_in user }

  describe "GET #day (search modal shell)" do
    let(:body) do
      get :day
      expect(response).to be_successful
      response.body
    end

    it "renders the modal shell with the id the toolbar button targets" do
      expect(body).to include('id="agenda-search"')
    end

    it "exposes the search endpoint URL on the root" do
      expect(body).to match(/data-search-url="[^"]*\/agenda_items\/search"/)
    end

    it "contains the anchors search.js queries by data attribute" do
      %w[
        data-search-input
        data-search-results
        data-search-idle
        data-search-past-status
      ].each do |attr|
        expect(body).to include(attr), "missing selector: #{attr}"
      end
      %w[future past].each do |section|
        expect(body).to include(%(data-search-section="#{section}"))
        expect(body).to include(%(data-search-items="#{section}"))
        expect(body).to include(%(data-search-empty="#{section}"))
      end
    end

    it "wires a toolbar button that opens the search modal" do
      expect(body).to match(/class="agenda-search-btn"[^>]*data-modal="#agenda-search"/)
    end
  end
end
