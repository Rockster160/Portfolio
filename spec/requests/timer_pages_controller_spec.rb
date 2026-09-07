require "rails_helper"

RSpec.describe TimerPagesController do
  let(:user) { create(:user) }

  before do
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  describe "POST /timers/pages" do
    it "stores meta so a throwaway page can be flagged temporary" do
      post timer_routes_pages_path,
        params: { timer_page: { name: "Trivia", slug: "trivia", meta: { temporary: true } } },
        as:     :json
      expect(response).to have_http_status(:created)
      expect(user.timer_pages.find_by(slug: "trivia").meta["temporary"]).to be(true)
    end
  end

  describe "POST /timers/pages/:id/duplicate" do
    let!(:page) { create(:timer_page, user: user, name: "Scores", slug: "scores") }
    let!(:counter) {
      create(
        :timer, user: user, timer_page: page, kind: :counter, duration_ms: nil,
        name: "Rocco", value: 17, reset_value: 0
      )
    }

    def duplicate!
      post duplicate_timer_routes_page_path(page), as: :json
      response.parsed_body
    end

    it "copies the board onto a new page with its own slug" do
      json = duplicate!
      expect(response).to have_http_status(:created)
      expect(json["name"]).to eq("Scores copy")
      expect(json["slug"]).to eq("scores-2")
      copy = user.timer_pages.find(json["id"])
      expect(copy.timers.map(&:name)).to eq(["Rocco"])
      expect(page.timers.count).to eq(1)
    end

    it "brings counters across at their start value, not mid-game" do
      copy = user.timer_pages.find(duplicate!["id"])
      expect(copy.timers.first.value).to eq(0)
      expect(counter.reload.value).to eq(17)
    end

    it "leaves countdowns unstarted" do
      create(
        :timer, user: user, timer_page: page, kind: :countdown, duration_ms: 60_000,
        started_at: Time.current, end_at: 1.minute.from_now
      )
      copy = user.timer_pages.find(duplicate!["id"])
      expect(copy.timers.where(kind: :countdown).first.started_at).to be_nil
    end

    it "repoints a chain callback at the copied timer, not the original" do
      chained = create(:timer, user: user, timer_page: page, kind: :counter, duration_ms: nil, name: "Total")
      counter.update!(callbacks: [{
        id:   "cb1",
        when: { type: "counter_reaches", value: 5 },
        then: { type: "chain", target_timer_id: chained.id, op: "increment", by: 1 },
      }])

      copy = user.timer_pages.find(duplicate!["id"])
      copied_source = copy.timers.find_by(name: "Rocco")
      copied_target = copy.timers.find_by(name: "Total")
      expect(copied_source.callbacks.first["then"]["target_timer_id"]).to eq(copied_target.id)
    end

    it "copies the page's quick buttons and page buttons" do
      page.quick_buttons.create!(user: user, label: "5m", duration_seconds: 300)
      page.page_buttons.create!(label: "Rules", target_url: "/jil/p/1")

      copy = user.timer_pages.find(duplicate!["id"])
      expect(copy.quick_buttons.map(&:label)).to eq(["5m"])
      expect(copy.page_buttons.map(&:label)).to eq(["Rules"])
    end

    it "takes the next free slug when a copy already exists" do
      duplicate!
      expect(duplicate!["slug"]).to eq("scores-3")
    end

    it "accepts a name for the copy" do
      post duplicate_timer_routes_page_path(page), params: { name: "Game 2" }, as: :json
      expect(response.parsed_body["name"]).to eq("Game 2")
    end
  end
end
