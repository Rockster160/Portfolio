require "rails_helper"

RSpec.describe SystemController, type: :controller do
  render_views

  let(:me) { User.me }

  # The JSON payload the Chart.js init reads.
  def chart_payload
    blob = response.body[%r{<script id="spend-data"[^>]*>(.+?)</script>}m, 1]
    JSON.parse(blob)
  end

  describe "GET #gpt_spending" do
    before { sign_in me }

    it "buckets spend by local day and by model, defaulting to a 30-day window" do
      tz = ActiveSupport::TimeZone["America/Denver"]
      convo = ByteConversation.create!(user: me, mode: :buddy, name: "Buddy")

      BuddyUsage.create!(user: me, byte_conversation: convo, model: "gpt-5.4-mini", cost_micros: 1_500)
      BuddyUsage.create!(user: me, byte_conversation: convo, model: "gpt-5.4", cost_micros: 4_000)
      old = BuddyUsage.create!(user: me, byte_conversation: convo, model: "gpt-5.4-mini", cost_micros: 900)
      old.update_column(:created_at, 3.days.ago)

      get :gpt_spending
      expect(response).to have_http_status(:ok)

      payload = chart_payload
      expect(payload["labels"].length).to eq(30)
      expect(payload["labels"].last).to eq(tz.today.strftime("%b %-d"))

      # Models ranked by spend desc; totals rendered in the legend.
      models = payload["datasets"].map { |d| d["label"] }
      expect(models).to eq(%w[gpt-5.4 gpt-5.4-mini])
      expect(response.body).to include("$0.0064") # total, last 30 days
      expect(response.body).to include("3</div>")  # api call count

      mini = payload["datasets"].find { |d| d["label"] == "gpt-5.4-mini" }
      today_i = payload["labels"].index(tz.today.strftime("%b %-d"))
      old_i = payload["labels"].index(3.days.ago.in_time_zone(tz).to_date.strftime("%b %-d"))
      expect(mini["data"][today_i]).to eq(0.0015)
      expect(mini["data"][old_i]).to eq(0.0009)
    end

    it "honors an allowed window and ignores a bogus one" do
      get :gpt_spending, params: { days: 7 }
      expect(chart_payload["labels"].length).to eq(7)

      get :gpt_spending, params: { days: 999 }
      expect(chart_payload["labels"].length).to eq(30)
    end

    it "buckets today by the hour for the 1-day window" do
      tz = ActiveSupport::TimeZone["America/Denver"]
      convo = ByteConversation.create!(user: me, mode: :buddy, name: "Buddy")

      two_pm = BuddyUsage.create!(user: me, byte_conversation: convo, model: "gpt-5.4-mini", cost_micros: 2_000)
      two_pm.update_column(:created_at, (tz.now.beginning_of_day + 14.hours).utc)

      get :gpt_spending, params: { days: 1 }
      expect(response).to have_http_status(:ok)

      payload = chart_payload
      expect(payload["labels"].length).to eq(24)
      expect(payload["labels"].first).to eq("12 AM")
      expect(payload["labels"]).to include("2 PM")
      expect(response.body).to include("Total, today")
      expect(response.body).to include("Per hour (avg)")

      mini = payload["datasets"].find { |d| d["label"] == "gpt-5.4-mini" }
      two_pm_i = payload["labels"].index("2 PM")
      expect(mini["data"][two_pm_i]).to eq(0.002)
      expect(mini["data"].sum).to eq(0.002) # nothing outside 2 PM
    end

    it "renders empty gracefully with no usage" do
      get :gpt_spending
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No GPT spending recorded")
      expect(chart_payload["datasets"]).to be_empty
    end
  end

  describe "access" do
    it "is not found for non-me users" do
      sign_in create(:user)
      get :gpt_spending
      expect(response).to have_http_status(:not_found)
    end
  end
end
