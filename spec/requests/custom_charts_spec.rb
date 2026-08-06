require "rails_helper"

RSpec.describe "CustomCharts", type: :request do
  let(:user) { create(:user) }
  let(:tz)   { ActiveSupport::TimeZone["America/Denver"] }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  def chart
    user.custom_charts.create!(
      name: "Pullups", query: "name::Pullups",
      config: { value_source: :notes, metric: :sum, bucket: :month, chart_type: :bar }
    )
  end

  describe "view rendering" do
    it "renders index, new, and edit without ERB errors" do
      c = chart

      get custom_charts_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Pullups")

      get new_custom_chart_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-cc-form")

      get edit_custom_chart_path(c)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("name::Pullups")
    end
  end

  describe "GET /custom_charts/:id" do
    it "renders the show page with an embedded payload" do
      user.action_events.create!(name: "Pullups", timestamp: tz.local(2026, 1, 10, 12), notes: "5")
      get custom_chart_path(chart)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-cc-payload")
    end
  end

  describe "GET /custom_charts/:id/data" do
    it "returns Chart.js-ready JSON and honors range/bucket overrides" do
      c = chart
      user.action_events.create!(name: "Pullups", timestamp: tz.local(2026, 1, 10, 12), notes: "5")
      user.action_events.create!(name: "Pullups", timestamp: tz.local(2026, 2, 10, 12), notes: "7")

      get data_custom_chart_path(c), params: { start_date: "2026-01-01", end_date: "2026-02-28", bucket: "month" }
      body = response.parsed_body

      expect(body["labels"]).to eq(["Jan 2026", "Feb 2026"])
      expect(body["datasets"].first["data"]).to eq([5, 7])
    end
  end

  describe "user isolation" do
    it "never returns another user's chart" do
      other = create(:user)
      stranger_chart = other.custom_charts.create!(name: "Secret", query: "name::X")

      get custom_chart_path(stranger_chart)
      # The app rescues RecordNotFound into a redirect rather than a raw 404;
      # either way the stranger's chart is never rendered.
      expect(response).not_to have_http_status(:ok)
      expect(response.body).not_to include("Secret")
    end

    it "only aggregates the current user's events" do
      c = chart
      other = create(:user)
      user.action_events.create!(name: "Pullups", timestamp: tz.local(2026, 1, 10, 12), notes: "5")
      other.action_events.create!(name: "Pullups", timestamp: tz.local(2026, 1, 10, 12), notes: "999")

      get data_custom_chart_path(c), params: { start_date: "2026-01-01", end_date: "2026-01-31", bucket: "month" }
      expect(response.parsed_body["datasets"].first["data"]).to eq([5])
    end
  end

  describe "CRUD" do
    it "creates a chart from form params" do
      expect {
        post custom_charts_path, params: {
          custom_chart: {
            name:   "Emotions",
            query:  "name::Feeling",
            config: { series_by: "data_keys", metric: "avg", bucket: "none", chart_type: "line" },
          },
        }
      }.to change { user.custom_charts.count }.by(1)

      created = user.custom_charts.last
      expect(created.series_by).to eq(:data_keys)
      expect(response).to redirect_to(custom_chart_path(created))
    end

    it "round-trips the invert_sign checkbox" do
      post custom_charts_path, params: {
        custom_chart: {
          name:   "Transactions",
          query:  "name::Transaction",
          config: { series_by: "sign", metric: "sum", invert_sign: "1" },
        },
      }
      expect(user.custom_charts.last.invert_sign).to be(true)
    end

    it "reads an unchecked invert_sign as false" do
      post custom_charts_path, params: {
        custom_chart: {
          name:   "Transactions",
          query:  "name::Transaction",
          config: { series_by: "sign", metric: "sum", invert_sign: "0" },
        },
      }
      expect(user.custom_charts.last.invert_sign).to be(false)
    end
  end

  describe "POST /custom_charts/preview" do
    it "builds an unsaved chart from posted config" do
      user.action_events.create!(name: "Feeling", timestamp: tz.local(2026, 1, 10, 12), data: { "Happy" => "80" })

      post preview_custom_charts_path, params: {
        custom_chart: {
          name:   "Preview",
          query:  "name::Feeling",
          config: { series_by: "data_keys", metric: "avg", bucket: "none" },
        },
        start_date:   "2026-01-01",
        end_date:     "2026-01-31",
      }
      body = response.parsed_body
      expect(body["time_axis"]).to be(true)
      expect(body["datasets"].first["label"]).to eq("Happy")
    end
  end
end
