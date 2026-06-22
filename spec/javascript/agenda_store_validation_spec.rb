require "rails_helper"
require "json"
require "open3"

# Locks the boundary contract of the AgendaStore: malformed or missing
# server envelopes MUST NOT mutate local state. The user-visible
# guarantee is that bad responses can't wipe a populated offline cache
# — every applyBootstrap/applyDelta/applyPage call must verify the
# envelope (server_ts, day_key) and required collections BEFORE it
# touches `state.items` or notifies subscribers.
#
# Runs the actual store.js inside Node so the spec catches drift between
# this checker and the validator the real PWA will use at runtime.
RSpec.describe "AgendaStore validation guard (JS-side)" do
  let(:runner_path) {
    Rails.root.join("spec", "javascript", "agenda_store_validation_runner.js").to_s
  }
  let(:results) {
    stdout, stderr, status = Open3.capture3("node", runner_path)
    raise "runner failed: #{stderr}" unless status.success?
    JSON.parse(stdout, symbolize_names: true)[:results]
  }
  let(:by_name) { results.to_h { |r| [r[:name].to_sym, r[:result]] } }

  it "rejects every malformed bootstrap and keeps the existing seed item alive" do
    expected_rejects = %i[
      bootstrap_rejects_null
      bootstrap_rejects_no_server_ts
      bootstrap_rejects_zero_server_ts
      bootstrap_rejects_no_day_key
      bootstrap_rejects_malformed_day_key
      bootstrap_rejects_no_items
      bootstrap_rejects_items_not_array
    ]
    expected_rejects.each do |name|
      result = by_name[name]
      expect(result[:accepted]).to eq(false), "expected #{name} to be rejected"
      expect(result[:preserved_existing_item]).to eq(true),
        "expected #{name} to preserve the existing seeded item"
    end
  end

  it "accepts a well-formed bootstrap" do
    expect(by_name[:bootstrap_accepts_valid][:accepted]).to eq(true)
  end

  it "rejects every malformed delta and keeps the existing seed item alive" do
    %i[delta_rejects_null delta_rejects_no_server_ts delta_rejects_malformed_day_key].each do |name|
      expect(by_name[name][:accepted]).to eq(false), "expected #{name} to be rejected"
      expect(by_name[name][:preserved_existing_item]).to eq(true),
        "expected #{name} to preserve the existing seeded item"
    end
  end

  it "accepts a well-formed delta" do
    expect(by_name[:delta_accepts_valid][:accepted]).to eq(true)
  end

  it "rejects every malformed page and keeps the existing seed item alive" do
    %i[page_rejects_null page_rejects_no_server_ts page_rejects_no_items].each do |name|
      expect(by_name[name][:accepted]).to eq(false), "expected #{name} to be rejected"
      expect(by_name[name][:preserved_existing_item]).to eq(true),
        "expected #{name} to preserve the existing seeded item"
    end
  end

  it "accepts a well-formed page" do
    expect(by_name[:page_accepts_valid][:accepted]).to eq(true)
  end
end
