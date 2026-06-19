require "rails_helper"

# Pin the PWA service-worker contract. The SW is served by Rails (not a
# static file) so we can interpolate fingerprinted asset paths and a
# deploy-stamped version into the cache key — every browser update
# auto-busts the cache without manual intervention.
RSpec.describe "agenda service worker (PWA)", type: :request do
  describe "GET /agenda_sw.js" do
    let(:response_body) { get "/agenda_sw.js"; response.body }
    let(:content_type) { response.media_type }

    it "is reachable without authentication (registration must succeed pre-login)" do
      get "/agenda_sw.js"
      expect(response).to be_successful
    end

    it "serves application/javascript so the browser will register it" do
      get "/agenda_sw.js"
      expect(response.media_type).to eq("application/javascript")
    end

    it "tells the browser not to cache the SW source itself" do
      get "/agenda_sw.js"
      cache_ctrl = response.headers["Cache-Control"].to_s
      # `expires_in 0` produces `max-age=0, private, must-revalidate` —
      # check the headline directive that prevents stale SW pinning.
      expect(cache_ctrl).to match(/max-age=0/)
      expect(cache_ctrl).to match(/must-revalidate/)
    end

    it "stamps a CACHE_NAME version into the SW source" do
      get "/agenda_sw.js"
      expect(response.body).to match(/CACHE_NAME = `agenda-/)
    end

    it "pre-caches the four canonical agenda shells (day/week/month/grid)" do
      get "/agenda_sw.js"
      expect(response.body).to include('"/agenda"')
      expect(response.body).to include('"/agenda/week"')
      expect(response.body).to include('"/agenda/month"')
      expect(response.body).to include('"/agenda/grid"')
    end

    it "pre-caches the agenda webmanifest so the install criteria are met offline" do
      get "/agenda_sw.js"
      expect(response.body).to include('"/agenda.webmanifest"')
    end

    it "treats /agenda/sync/* as network-first (data freshness > offline cache)" do
      get "/agenda_sw.js"
      expect(response.body).to include('"/agenda/sync/"')
      expect(response.body).to include("networkFirst")
    end

    it "leaves mutations untouched (POST/PATCH/DELETE)" do
      # The fetch handler bails early for non-GET requests so the page's
      # offline ops queue keeps owning retry semantics.
      get "/agenda_sw.js"
      expect(response.body).to include("req.method !== \"GET\"")
    end
  end
end
