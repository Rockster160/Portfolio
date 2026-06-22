require "rails_helper"
require "json"
require "open3"

# Regression guard for "future TMS occurrences don't show the
# 23-minute travel band." The materialized row (today's TMS) carried
# `metadata["travel_minutes"] = 23` and rendered the band fine; future
# occurrences come from the JS phantom expander which used to hardcode
# `"travel-minutes": 0`, so the band height computed to zero. This spec
# locks the inheritance contract on the JS side so a future refactor
# of `recurrence.js#buildPhantom` can't silently break it again.
RSpec.describe "AgendaRecurrence phantom travel inheritance (JS-side)" do
  let(:runner_path) {
    Rails.root.join("spec", "javascript", "phantom_travel_inheritance_runner.js").to_s
  }
  let(:by_name) {
    stdout, stderr, status = Open3.capture3("node", runner_path)
    raise "runner failed: #{stderr}" unless status.success?
    JSON.parse(stdout, symbolize_names: true)[:cases].to_h { |c| [c[:name].to_sym, c[:attrs]] }
  }

  it "inherits top-level metadata.travel_minutes (legacy shape)" do
    a = by_name[:legacy_travel_minutes_only]
    expect(a[:"travel-minutes"]).to eq(23)
  end

  it "inherits every nested metadata.travel.* field" do
    a = by_name[:full_travel_chain]
    expect(a[:"travel-minutes"]).to       eq(15)
    expect(a[:"resolved-address"]).to     eq("13123 S 5600 W, Herriman, UT 84096")
    expect(a[:"travel-from"]).to          eq("Home St")
    expect(a[:"travel-from-kind"]).to     eq("home")
    expect(a[:"chain-predecessor-id"]).to eq(99)
    expect(a[:"chain-successor-id"]).to   eq(100)
    expect(a[:"chain-prev-end-epoch"]).to eq(1234)
    expect(a[:"leave-at-epoch"]).to       eq(5678)
    expect(a[:"arrive-early-minutes"]).to eq(5)
  end

  it "defaults to zero / empty when the schedule has no metadata" do
    a = by_name[:no_metadata]
    expect(a[:"travel-minutes"]).to       eq(0)
    expect(a[:"resolved-address"]).to     eq("")
    expect(a[:"travel-from"]).to          eq("")
    expect(a[:"travel-from-kind"]).to     eq("")
    expect(a[:"chain-predecessor-id"]).to eq("")
    expect(a[:"chain-successor-id"]).to   eq("")
    expect(a[:"chain-prev-end-epoch"]).to eq("")
    expect(a[:"leave-at-epoch"]).to       eq("")
  end
end
