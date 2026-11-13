require "rails_helper"

RSpec.describe TimersController do
  let(:user) { create(:user) }

  before do
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  describe "GET /timers" do
    it "renders the page shell, seeding default quick buttons on first visit" do
      expect { get timers_path }.to change { user.timer_quick_buttons.count }.from(0).to(7)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("timers-page", "timers-bootstrap")
    end
  end

  describe "POST /timers/items" do
    it "creates a countdown timer" do
      post timer_routes_items_path,
        params: { timer: { kind: :countdown, name: "Tea", duration_ms: 60_000 }, tab_id: "abc" },
        as: :json
      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json.dig("timer", "kind")).to eq("countdown")
      expect(json.dig("timer", "name")).to eq("Tea")
    end

    it "stores the full dial_config including all sections + subs" do
      payload = {
        timer: {
          kind: :dial,
          duration_ms: 1,
          dial_config: { sections: 8.times.map { |i| { name: "S#{i}", subs: %w[a b c] } } },
        },
      }
      post timer_routes_items_path, params: payload, as: :json
      expect(response).to have_http_status(:created)
      t = user.timers.last
      expect(t.dial_config["sections"].length).to eq(8)
      expect(t.dial_config["sections"].first["subs"]).to eq(%w[a b c])
      expect(t.send(:dial_step_count)).to eq(24)
    end

    it "creates and starts in one round-trip with start_immediately + HTML redirect" do
      Sidekiq::Testing.fake! do
        post timer_routes_items_path,
          params: {
            start_immediately: "1",
            timer: { kind: :countdown, name: "Quick", duration_ms: 60_000 },
          }
      end
      expect(response).to redirect_to(timers_path)
      created = user.timers.last
      expect(created.name).to eq("Quick")
      expect(created.started_at).to be_present
      expect(created.end_at).to be_present
    end
  end

  describe "POST /timers/items/:id/start" do
    let(:timer) { create(:timer, user: user, duration_ms: 60_000) }

    it "starts the timer" do
      Sidekiq::Testing.fake! do
        post timer_routes_start_item_path(timer), as: :json
      end
      expect(response).to have_http_status(:ok)
      expect(timer.reload.started_at).to be_present
      expect(timer.reload.end_at).to be_present
    end
  end

  describe "PATCH /timers/items/:id (callbacks)" do
    let(:timer) { create(:timer, user: user, duration_ms: 60_000) }

    it "persists the (when, then) callback shape verbatim via strong params" do
      patch timer_routes_item_path(timer),
        params: {
          timer: {
            callbacks: [
              {
                id:   "cb-1",
                when: { type: "countdown_at", remaining_ms: 30_000 },
                then: { type: "sound", chime: "bell", cadence: "10s" },
              },
            ],
          },
        },
        as: :json

      expect(response).to have_http_status(:ok)
      cb = timer.reload.callbacks.first
      expect(cb["when"]).to include("type" => "countdown_at", "remaining_ms" => 30_000)
      expect(cb["then"]).to include("type" => "sound", "chime" => "bell", "cadence" => "10s")
    end
  end

  describe "GET /timers/sync" do
    it "returns timer + page + quick button payload" do
      get timers_sync_path, as: :json
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.keys).to include("server_ts", "timers", "pages", "quick_buttons", "archived_ids")
    end
  end

  describe "Buddy's timers" do
    let!(:buddy_page) { Buddy::Timers.page_for(user) }
    let!(:buddy_timer) { create(:timer, user: user, timer_page: buddy_page, name: "Pasta") }
    let!(:home_timer) { create(:timer, user: user, name: "Laundry") }

    it "leaves Buddy's page and timers out of the timers app" do
      get timers_sync_path, as: :json
      json = response.parsed_body
      expect(json["timers"].pluck("id")).to eq([home_timer.id])
      expect(json["pages"].pluck("id")).not_to include(buddy_page.id)
    end

    it "has no page to open at Buddy's slug" do
      get timer_page_path(slug: Buddy::Timers::PAGE_SLUG)
      expect(response).not_to have_http_status(:ok)
      expect(response.body).not_to include("Pasta")
    end

    it "leaves the buddy slug free for a page of the person's own" do
      theirs = user.timer_pages.create!(name: "Buddy", slug: "buddy")
      get timer_page_path(slug: "buddy")
      expect(response).to have_http_status(:ok)
      get timers_sync_path, as: :json
      expect(response.parsed_body["pages"].pluck("id")).to include(theirs.id)
    end
  end

  describe "GET /timers/page/:slug/manifest.webmanifest" do
    let!(:page) { user.timer_pages.create!(slug: "slime-colony", name: "Slime Colony") }

    it "renders a per-page manifest with a unique id, scope, and start_url" do
      get timer_page_manifest_path(slug: "slime-colony", t: page.install_token)
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/manifest+json")
      json = JSON.parse(response.body)
      expect(json["id"]).to eq("timers-page-slime-colony")
      expect(json["scope"]).to eq("/timers/page/slime-colony")
      expect(json["start_url"]).to eq("/timers/page/slime-colony?source=pwa")
      expect(json["name"]).to eq("Slime Colony")
      expect(json["theme_color"]).to eq("#0d1117")
      expect(json["icons"].pluck("src")).to include("/timers_favicon/android-chrome-512x512.png")
    end

    it "opens nothing without the page's own token" do
      other = user.timer_pages.create!(slug: "other", name: "Other")
      get timer_page_manifest_path(slug: "slime-colony")
      expect(response).to have_http_status(:not_found)
      get timer_page_manifest_path(slug: "slime-colony", t: other.install_token)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "a page's home screen icon" do
    let!(:page) { user.timer_pages.create!(slug: "slime-colony", name: "Slime Colony") }
    let(:png) { "\x89PNG\r\n\x1A\n".b + ("pixels" * 10) }
    let(:data_url) { "data:image/png;base64,#{Base64.strict_encode64(png)}" }

    def set_icon(fields={ icon: "⏰", icon_color: "#224466", icon_data_url: data_url })
      patch "/timers/pages/#{page.id}", params: { timer_page: fields }, as: :json
    end

    it "keeps the icon picked in Settings and serves it for the installed page" do
      set_icon
      expect(response).to have_http_status(:ok)
      icon_url = response.parsed_body["icon_url"]
      expect(icon_url).to start_with("/timers/page/slime-colony/icon.png?t=")
      expect(response.parsed_body).to include("icon" => "⏰", "icon_color" => "#224466")

      get timer_page_path(slug: "slime-colony")
      expect(response.body).to include(%(rel="apple-touch-icon" sizes="180x180" href="#{CGI.escapeHTML(icon_url)}"))

      get logout_path
      get icon_url
      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(png)

      get timer_page_manifest_path(slug: "slime-colony", t: page.install_token)
      json = JSON.parse(response.body)
      expect(json["icons"].pluck("src")).to all(eq(icon_url))
      expect(json["theme_color"]).to eq("#224466")
    end

    it "goes back to the timers icon when cleared" do
      set_icon
      set_icon(icon: "", icon_color: "", icon_data_url: "")
      expect(page.reload).to have_attributes(icon: nil, icon_png: nil)
      expect(response.parsed_body["icon_url"]).to be_nil
    end
  end

  describe "GET /timers/page/:slug" do
    let!(:page) { user.timer_pages.create!(slug: "slime-colony", name: "Slime Colony") }

    it "links the per-page manifest so the PWA installs distinctly" do
      get timer_page_path(slug: "slime-colony")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(href="/timers/page/slime-colony/manifest.webmanifest?t=))
      expect(response.body).not_to include(%(href="/timers.webmanifest"))
    end
  end

  describe "DELETE /timers/items/:id" do
    let!(:timer) { create(:timer, user: user, duration_ms: 60_000) }

    it "hard-deletes the row and its share tokens so it can't resurrect on reload" do
      TimerShareToken.create!(user: user, timer: timer)
      expect {
        delete timer_routes_item_path(timer), as: :json
      }.to change { Timer.unscoped.where(id: timer.id).count }.from(1).to(0)
      expect(response).to have_http_status(:ok)
      expect(TimerShareToken.where(timer_id: timer.id)).to be_empty
    end
  end

  describe "POST /timers/items/:id/increment" do
    let!(:counter) {
      create(:timer, user: user, kind: :counter, duration_ms: nil, value: 43, step: 3)
    }

    it "scales `by` through the counter's step, and applies `amount` as typed" do
      [[{ by: 1 }, 46], [{ amount: 18 }, 61], [{ amount: -18 }, 25]].each do |params, value|
        counter.update!(value: 43)
        post timer_routes_increment_item_path(counter), params: params, as: :json

        expect(response).to have_http_status(:ok)
        expect(counter.reload.value).to eq(value), params.to_s
        expect(response.parsed_body.dig("timer", "value")).to eq(value)
      end
    end
  end

  describe "POST /timers/items/bulk" do
    let!(:page) { create(:timer_page, user: user) }

    def bulk(names, extra = {})
      post timer_routes_bulk_items_path,
        params: {
          timer_page_id: page.id,
          timers:        names.map { |n| { kind: :counter, name: n, value: 0 }.merge(extra) },
        },
        as: :json
    end

    it "creates one timer per row in a single request, the first name typed at the top" do
      expect { bulk(%w[Rocco Eve Chelsea]) }.to change { page.timers.count }.from(0).to(3)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["timers"].map { |t| t["name"] }).to eq(%w[Rocco Eve Chelsea])
      expect(page.timers.ordered.map(&:name)).to eq(%w[Rocco Eve Chelsea])
    end

    it "puts a later batch above the first, the way a single create does" do
      bulk(%w[Rocco Eve])
      bulk(%w[Chelsea Jack])
      expect(page.timers.ordered.map(&:name)).to eq(%w[Chelsea Jack Rocco Eve])
    end

    it "keeps callbacks and card size sent with a row" do
      bulk(%w[Steep], width: 3, callbacks: [{ id: "cb", when: { type: :complete }, then: { type: :sound, chime: :soft } }])
      expect(page.timers.first.callbacks.first["then"]["chime"]).to eq("soft")
      expect(page.timers.first.width).to eq(3)
    end

    it "builds a dial from a row's sections" do
      post timer_routes_bulk_items_path,
        params: {
          timer_page_id: page.id,
          timers:        [{
            kind:        :dial,
            name:        "Turn",
            dial_config: { sections: [{ name: "Rocco", subs: [] }, { name: "Eve", subs: [] }], start_offset: 0 },
          }],
        },
        as: :json
      expect(page.timers.first.dial_config["sections"].pluck("name")).to eq(%w[Rocco Eve])
    end

    it "puts rows sent without a page on Home" do
      post timer_routes_bulk_items_path,
        params: { timers: [{ kind: :counter, name: "Rocco" }, { kind: :counter, name: "Eve" }] },
        as:     :json
      expect(response).to have_http_status(:created)
      expect(user.timers.where(timer_page_id: nil).pluck(:name)).to contain_exactly("Rocco", "Eve")
    end

    it "writes nothing to a page belonging to someone else" do
      other = create(:timer_page, user: create(:user))
      post timer_routes_bulk_items_path,
        params: { timer_page_id: other.id, timers: [{ kind: :counter, name: "Nope" }] },
        as: :json
      expect(response).not_to have_http_status(:created)
      expect(other.timers.count).to eq(0)
    end
  end
end
