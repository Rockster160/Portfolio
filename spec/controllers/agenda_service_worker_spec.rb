require "rails_helper"

# The SW is served by Rails (not a static file) so fingerprinted asset paths and
# a deploy-stamped version can be interpolated into the cache key. The source
# checks below pin the offline-first contract: atomic shell+asset warming,
# verify-before-purge in activate, multi-tier fallback in fetch, and the
# SHELL_MARKER guard against caching error pages.
RSpec.describe "agenda service worker (PWA)", type: :request do
  describe "GET /agenda_sw.js" do
    it "is served pre-login as uncached javascript", :aggregate_failures do
      get "/agenda_sw.js"

      expect(response).to be_successful
      expect(response.media_type).to eq("application/javascript")
      cache_ctrl = response.headers["Cache-Control"].to_s
      expect(cache_ctrl).to match(/max-age=0/)
      expect(cache_ctrl).to match(/must-revalidate/)
    end

    it "carries the caching and offline-fallback contract", :aggregate_failures do
      get "/agenda_sw.js"
      body = response.body

      # Versioned cache name, also broadcast back to the page via get_version.
      expect(body).to match(/CACHE\s*=\s*`agenda-/)
      expect(body).to match(/sw_version.*cache:\s*CACHE/m)

      # The canonical shells and both manifests are pre-cached.
      ["/agenda", "/agenda/week", "/agenda/month", "/agenda/grid",
       "/agenda.webmanifest", "/agenda_calendar.webmanifest"].each do |path|
        expect(body).to include(%("#{path}"))
      end

      # ?date= and ?source= variants collapse onto the same cached shell.
      expect(body).to include("isShellRequest", "SHELL_PASSTHROUGH_PARAMS", "cache.match(url.pathname)")

      # Sync is network-first; mutations are left to the page's offline queue.
      expect(body).to include('"/agenda/sync/"', "networkFirst")
      expect(body).to include("req.method !== \"GET\"")

      # A shell is only cached after every asset is, and only if it is a real shell.
      expect(body).to include("function warmShellAssets", "results.every(Boolean)")
      expect(body).to include(%q(<meta name="agenda-shell" content="ok">), "isValidShellBody")

      # The old cache is only purged once the new one has a shell.
      expect(body).to match(/if\s*\(\s*hasShell\s*\)/)
      expect(body).to include("function anyCachedShell", "function matchFromOldCaches")

      # iOS PWAs drop MessagePort replies, so the version goes out as a broadcast.
      expect(body).to include('action === "get_version"', 'kind: "sw_version"', "broadcastToClients")
    end
  end
end
