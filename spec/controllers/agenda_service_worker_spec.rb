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

    it "stamps a versioned CACHE name into the SW source" do
      # `CACHE = "agenda-<digest>"` — used as the named cache and broadcast
      # back to the page via `get_version`. The digest portion is what
      # auto-bumps on a JS/CSS deploy via `sw_cache_version`.
      get "/agenda_sw.js"
      expect(response.body).to match(/CACHE\s*=\s*`agenda-/)
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

    it "pre-caches the calendar webmanifest so the Mac PWA installs offline" do
      # Mac-style /agenda/grid + /agenda/month PWA — separate id from
      # the iOS day-list PWA so both can be installed side-by-side.
      get "/agenda_sw.js"
      expect(response.body).to include('"/agenda_calendar.webmanifest"')
    end

    it "collapses ?date= and ?source= variants onto the same cached shell" do
      # Belt-and-suspenders for offline view-to-view navigation: every
      # canonical shell URL is pre-cached, and the SW's shell-match looks
      # up by `url.pathname` (ignoring search) so `/agenda?date=2026-06-22`
      # and `/agenda?source=pwa` both hit the same cached entry. Without
      # this, every PWA launch (which appends `?source=pwa` per the
      # manifest start_url) would bypass the cache and fall through to
      # network → blank screen offline.
      get "/agenda_sw.js"
      expect(response.body).to include("isShellRequest")
      expect(response.body).to include("SHELL_PASSTHROUGH_PARAMS")
      expect(response.body).to include("cache.match(url.pathname)")
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

    # ---- Offline-first robustness contract -------------------------------
    # The next block locks the behavior that keeps users on a working app
    # offline: atomic shell+asset warming, verify-before-purge in activate,
    # multi-tier fallback in fetch, and the SHELL_MARKER guard against
    # caching error pages. Any change that removes one of these is a
    # regression toward the blank-screen scenario.

    it "ships the warmShellAssets helper for atomic per-shell warming" do
      # A shell is only `cache.put`'d after EVERY referenced asset has been
      # fetched + cached. A failed asset means the previous (working) shell
      # stays live instead of being replaced by a broken one.
      get "/agenda_sw.js"
      expect(response.body).to include("function warmShellAssets")
      expect(response.body).to include("results.every(Boolean)")
    end

    it "validates the shell body carries the agenda-shell meta marker" do
      # Guards the cache from being poisoned by a 200 OK error page, a
      # wrong-controller render, or an auth interstitial that happened to
      # land at /agenda. Without this, a logged-out PWA could cache a
      # login redirect HTML as the shell and never recover.
      get "/agenda_sw.js"
      expect(response.body).to include(%q(<meta name="agenda-shell" content="ok">))
      expect(response.body).to include("isValidShellBody")
    end

    it "verifies the new cache has a shell before deleting the old one" do
      # An offline / partial install must NOT delete the previous cache —
      # doing so would leave the user with nothing to serve on the next
      # offline visit. The verify-before-purge pattern keeps the old cache
      # alive as a fallback until the new install succeeds.
      get "/agenda_sw.js"
      expect(response.body).to include("hasShell")
      expect(response.body).to match(/if\s*\(\s*hasShell\s*\)/)
    end

    it "exposes anyCachedShell + matchFromOldCaches as last-resort fallback" do
      # When the current cache misses AND the network misses, the SW
      # serves ANY cached shell — even from a prior `agenda-*` cache.
      # This is the final guarantee against a blank screen.
      get "/agenda_sw.js"
      expect(response.body).to include("function anyCachedShell")
      expect(response.body).to include("function matchFromOldCaches")
    end

    it "responds to get_version with a broadcast (NOT a port reply)" do
      # iOS PWAs silently drop MessagePort replies from a SW. The page-side
      # version badge relies on `broadcastToClients` hitting its existing
      # message listener.
      get "/agenda_sw.js"
      expect(response.body).to include('action === "get_version"')
      expect(response.body).to include('kind: "sw_version"')
      expect(response.body).to include("broadcastToClients")
    end

    it "stamps the CACHE_NAME version into the get_version payload" do
      # The page-script strips the `agenda-` prefix to display the bare
      # version digest. Without the CACHE constant in the payload there's
      # nothing to display.
      get "/agenda_sw.js"
      expect(response.body).to match(/sw_version.*cache:\s*CACHE/m)
    end
  end
end
