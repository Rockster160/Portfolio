require "rails_helper"

RSpec.describe Buddy::TimersController, type: :controller do
  let(:user) { User.me }

  before do
    sign_in user
    allow(MonitorChannel).to receive(:broadcast_to)
  end

  around { |ex|
    Sidekiq::Testing.fake! {
      TimerFireWorker.clear
      ex.run
    }
  }

  def buddy_timer(seconds: 120, label: nil)
    Buddy::Timers.create!(user: user, seconds: seconds, label: label)
  end

  describe "GET #index" do
    it "returns the Buddy page id and only Buddy timers" do
      mine = buddy_timer(label: "Tea")
      other_page = user.timer_pages.create!(slug: "work", name: "Work")
      user.timers.create!(kind: :countdown, duration_ms: 60_000, timer_page: other_page)

      get :index
      body = response.parsed_body

      expect(response).to be_successful
      expect(body["page_id"]).to eq(Buddy::Timers.page_for(user).id)
      expect(body["timers"].pluck("id")).to eq([mine.id])
    end
  end

  describe "lifecycle actions" do
    it "pauses and resumes" do
      timer = buddy_timer

      post :pause, params: { id: timer.id }
      expect(response).to be_successful
      expect(timer.reload.paused?).to be(true)

      post :resume, params: { id: timer.id }
      expect(timer.reload.running?).to be(true)
    end

    it "confirms a fired timer, clearing the fired state" do
      timer = buddy_timer
      timer.update!(fired_at: Time.current)

      post :confirm, params: { id: timer.id }
      expect(response).to be_successful
      expect(timer.reload.fired_at).to be_nil
    end

    it "archives on destroy" do
      timer = buddy_timer

      delete :destroy, params: { id: timer.id }
      expect(response).to have_http_status(:no_content)
      expect(timer.reload.archived_at).to be_present
    end
  end

  describe "scoping" do
    it "404s for a timer that isn't on the Buddy page" do
      other_page = user.timer_pages.create!(slug: "work", name: "Work")
      board_timer = user.timers.create!(kind: :countdown, duration_ms: 60_000, timer_page: other_page)

      post :pause, params: { id: board_timer.id }
      # Not found → the app redirects rather than pausing a non-Buddy timer.
      expect(response).not_to be_successful
      expect(board_timer.reload.paused?).to be(false)
    end
  end
end
