require "rails_helper"

RSpec.describe TimersController do
  let(:user) { create(:user) }

  before do
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  describe "GET /timers" do
    it "renders the page shell" do
      get timers_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("timers-page")
      expect(response.body).to include("timers-bootstrap")
    end

    it "seeds default quick buttons on first visit" do
      expect { get timers_path }.to change { user.timer_quick_buttons.count }.from(0).to(7)
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

  describe "GET /timers/page/:slug/manifest.webmanifest" do
    let!(:page) { user.timer_pages.create!(slug: "slime-colony", name: "Slime Colony") }

    it "renders a per-page manifest with a unique id, scope, and start_url" do
      get timer_page_manifest_path(slug: "slime-colony")
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/manifest+json")
      json = JSON.parse(response.body)
      expect(json["id"]).to eq("timers-page-slime-colony")
      expect(json["scope"]).to eq("/timers/page/slime-colony")
      expect(json["start_url"]).to eq("/timers/page/slime-colony?source=pwa")
      expect(json["name"]).to eq("Slime Colony")
    end

  end

  describe "GET /timers/page/:slug" do
    let!(:page) { user.timer_pages.create!(slug: "slime-colony", name: "Slime Colony") }

    it "links the per-page manifest so the PWA installs distinctly" do
      get timer_page_path(slug: "slime-colony")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(href="/timers/page/slime-colony/manifest.webmanifest"))
      expect(response.body).not_to include(%(href="/timers.webmanifest"))
    end
  end

  describe "DELETE /timers/items/:id" do
    let!(:timer) { create(:timer, user: user, duration_ms: 60_000) }

    it "hard-deletes the row so it can't resurrect on reload" do
      expect {
        delete timer_routes_item_path(timer), as: :json
      }.to change { Timer.unscoped.where(id: timer.id).count }.from(1).to(0)
      expect(response).to have_http_status(:ok)
    end

    it "removes share tokens via dependent: :destroy" do
      TimerShareToken.create!(user: user, timer: timer)
      expect {
        delete timer_routes_item_path(timer), as: :json
      }.to change { TimerShareToken.where(timer_id: timer.id).count }.from(1).to(0)
    end
  end

  describe "POST /timers/items/:id/increment" do
    let!(:counter) {
      create(:timer, user: user, kind: :counter, duration_ms: nil, value: 43, step: 3)
    }

    it "scales `by` through the counter's step" do
      post timer_routes_increment_item_path(counter), params: { by: 1 }, as: :json
      expect(counter.reload.value).to eq(46)
    end

    it "applies `amount` as typed, whatever the step is" do
      post timer_routes_increment_item_path(counter), params: { amount: 18 }, as: :json
      expect(response).to have_http_status(:ok)
      expect(counter.reload.value).to eq(61)
      expect(response.parsed_body.dig("timer", "value")).to eq(61)
    end

    it "applies a negative `amount`" do
      post timer_routes_increment_item_path(counter), params: { amount: -18 }, as: :json
      expect(counter.reload.value).to eq(25)
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

    it "creates one timer per row on the page in a single request" do
      expect { bulk(%w[Rocco Eve Chelsea]) }.to change { page.timers.count }.from(0).to(3)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["timers"].map { |t| t["name"] }).to eq(%w[Rocco Eve Chelsea])
    end

    it "orders them so the first name typed sits at the top of the board" do
      bulk(%w[Rocco Eve Chelsea])
      expect(page.timers.ordered.map(&:name)).to eq(%w[Rocco Eve Chelsea])
    end

    it "puts a later batch above the first, the way a single create does" do
      bulk(%w[Rocco Eve])
      bulk(%w[Chelsea Jack])
      expect(page.timers.ordered.map(&:name)).to eq(%w[Chelsea Jack Rocco Eve])
    end

    it "keeps callbacks sent with a row" do
      bulk(%w[Steep], callbacks: [{ id: "cb", when: { type: :complete }, then: { type: :sound, chime: :soft } }])
      expect(page.timers.first.callbacks.first["then"]["chime"]).to eq("soft")
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
