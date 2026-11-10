require "rails_helper"

# A chart drawn in the thread is a chart the Charts page could have drawn, and
# can be kept there as it stands.
RSpec.describe Buddy::Charts do
  let(:user)   { create(:user) }
  let(:convo)  { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:tz)     { ActiveSupport::TimeZone["America/Denver"] }
  let(:tool)   { Buddy::Tools[:show_chart] }
  let(:ctx)    { Buddy::ToolContext.new(user, conversation: convo) }

  before { allow(Buddy::ActivityChip).to receive(:broadcast) }

  def run(payload)
    resolved = payload.merge(tool[:confirm].call(payload, ctx)[:resolved])
    tool[:execute].call(resolved, ctx)
  end

  it "draws a new one in the thread and tells Buddy its numbers", :aggregate_failures do
    user.action_events.create!(name: "Check-in", timestamp: 2.days.ago, data: { "Feeling" => "4" })
    user.action_events.create!(name: "Check-in", timestamp: 1.day.ago, data: { "Feeling" => "8" })

    result = run({
      name:       "Feelings",
      query:      "name::Check-in",
      series_by:  :data_keys,
      metric:     :avg,
      bucket:     :day,
      range:      "7d",
      chart_type: :line,
    })

    expect(result[:series]).to contain_exactly(include(label: "Feeling", average: 6.0, low: 4.0, high: 8.0))
    message = convo.byte_messages.last
    drawn = message.metadata["chart"]
    expect(message.body).to eq("📈 Feelings")
    expect(drawn).to include("name" => "Feelings", "query" => "name::Check-in", "saved_id" => nil)
    expect(drawn["config"]).to include("series_by" => "data_keys", "metric" => "avg", "range" => "7d")
    expect(drawn.dig("payload", "datasets").pluck("label")).to eq(["Feeling"])
  end

  it "shows a saved one by a loose name, with the window they asked for" do
    saved = user.custom_charts.create!(name: "Morning check-in", query: "name::Check-in", config: { range: "3mo" })

    run({ saved: "check-in", range: "30d" })

    drawn = convo.byte_messages.last.metadata["chart"]
    expect(drawn["name"]).to eq("Morning check-in")
    expect(drawn["config"]).to include("range" => "30d")
    expect(drawn["saved_id"]).to be_nil
    expect(saved.reload.config).to include("range" => "3mo")
  end

  it "marks a saved one as saved when nothing about it changed" do
    saved = user.custom_charts.create!(name: "Morning check-in", query: "name::Check-in", config: {})

    run({ saved: "Morning check-in" })

    expect(convo.byte_messages.last.metadata.dig("chart", "saved_id")).to eq(saved.id)
  end

  it "refuses an option the editor wouldn't offer" do
    expect {
      tool[:confirm].call({ query: "name::X", value_source: :data }, ctx)
    }.to raise_error(/data_key/)
    expect {
      tool[:confirm].call({ saved: "nothing like it" }, ctx)
    }.to raise_error(/no saved chart/)
  end

  it "saves the drawn chart to the Charts page once" do
    run({ name: "Coffee", query: "name::Coffee" })
    message = convo.byte_messages.last

    chart = described_class.save!(user, message)
    again = described_class.save!(user, message.reload)

    expect(again).to eq(chart)
    expect(user.custom_charts.where(name: "Coffee").count).to eq(1)
    expect(chart.query).to eq("name::Coffee")
    expect(message.reload.metadata.dig("chart", "saved_id")).to eq(chart.id)
  end
end
