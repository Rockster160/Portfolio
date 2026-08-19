require "rails_helper"
require "json"
require "open3"

# Parity guard: the chips are rendered by Ruby and re-toggled by JS.
#
# The server builds each chip's href with SystemController#toggled_query, and
# from the first click onward the same chip is handled in the browser so the bar
# updates without a reload. Two implementations of one algebra, and every case
# where they disagree is a chip whose href says one thing and whose click does
# another — the query silently stops describing the list.
#
# Add a fixture for every shape either side learns to handle.
RSpec.describe "Query chip parity (Ruby vs JS)" do
  # The Ruby lives in SystemController as private methods over `@query`, which
  # is exactly how the real pages call it.
  def ruby_toggle(query, field, value, options)
    controller = SystemController.new
    controller.instance_variable_set(:@query, query)
    controller.send(:toggled_query, field, value, options)
  end

  def js_toggle(cases)
    runner = Rails.root.join("spec", "javascript", "query_chips_runner.js").to_s
    stdout, stderr, status = Open3.capture3("node", runner, stdin_data: { cases: cases }.to_json)
    raise "query_chips_runner failed: #{stderr}" unless status.success?

    JSON.parse(stdout).fetch("results")
  end

  FIXTURES = [
    # Nothing typed yet.
    { query: "", field: "kind", value: "followup", options: %w[concept preference stash followup] },
    # Added alongside prose, which has to survive untouched.
    { query: "hospital", field: "kind", value: "followup", options: %w[concept preference stash followup] },
    # Second value for the same field becomes an OR group, in the page's order.
    { query: "kind:followup", field: "kind", value: "concept", options: %w[concept preference stash followup] },
    # Third into an existing group.
    {
      query: "(kind:concept OR kind:followup)", field: "kind", value: "stash",
      options: %w[concept preference stash followup],
    },
    # Clicking a lit chip takes it back out and leaves the rest.
    {
      query: "(kind:concept OR kind:followup) hospital", field: "kind", value: "concept",
      options: %w[concept preference stash followup],
    },
    # Down to one: the group collapses back to a lone term rather than a
    # one-item OR.
    {
      query: "(kind:concept OR kind:followup)", field: "kind", value: "followup",
      options: %w[concept preference stash followup],
    },
    # The last one out leaves the prose alone and no empty parens behind.
    { query: "kind:followup hospital", field: "kind", value: "followup", options: %w[concept followup] },
    # Another field's terms are not this field's business.
    {
      query: "who:eve severity>50", field: "kind", value: "stash",
      options: %w[concept preference stash followup],
    },
    # A negated term names something to EXCLUDE, so it is not a selection —
    # clicking the chip adds the positive one and leaves the exclusion.
    { query: "-kind:stash", field: "kind", value: "concept", options: %w[concept stash] },
    # Quoted values, which is how anything with a space is written.
    { query: "", field: "category", value: "eat out", options: ["eat out", "groceries"] },
    {
      query: "category:\"eat out\"", field: "category", value: "groceries",
      options: ["eat out", "groceries"],
    },
    # Case is not part of the value.
    { query: "KIND:Followup", field: "kind", value: "followup", options: %w[concept followup] },
    # A value no longer on offer can't be clicked off, so it is dropped rather
    # than stranded.
    { query: "(kind:ghost OR kind:concept)", field: "kind", value: "stash", options: %w[concept stash] },
    # The real starting state of the memories page.
    {
      query: SystemController::DEFAULT_MEMORY_QUERY, field: "status", value: "dropped",
      options: %w[active deferred done dropped],
    },
    {
      query: SystemController::DEFAULT_MEMORY_QUERY, field: "status", value: "active",
      options: %w[active deferred done dropped],
    },
    # Banking's own fields, so the other page using this is covered too.
    { query: "payee:amazon", field: "account", value: "4821", options: %w[4821 9930] },
    { query: "(account:4821 OR account:9930)", field: "account", value: "9930", options: %w[4821 9930] },
  ].freeze

  it "produces the same query on both sides for every shape" do
    expected = FIXTURES.map { |f| ruby_toggle(f[:query], f[:field], f[:value], f[:options]) }

    js_toggle(FIXTURES).each_with_index do |actual, i|
      f = FIXTURES[i]
      expect(actual).to eq(expected[i]),
        "#{f[:field]}:#{f[:value]} on #{f[:query].inspect}\n  ruby: #{expected[i].inspect}\n  js:   #{actual.inspect}"
    end
  end
end
