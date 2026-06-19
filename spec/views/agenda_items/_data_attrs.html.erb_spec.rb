require "rails_helper"

# Pin the shared agenda-item data-attribute payload that's embedded
# inside the wrapper tags in `_item.html.erb` (day/week list),
# `calendar.html.erb` (week timegrid), and `cal_month.html.erb` (timed
# items + all-day seed nodes). Everything `agenda.js` reads via
# dataset.* lives here, so any drift between views becomes a single
# rendering bug instead of four near-identical bugs.
RSpec.describe "agenda_items/_data_attrs" do
  let(:user) { User.me }
  let(:agenda) { Agenda.find_by(user: user, name: "Rockster160") || Agenda.create!(user: user, name: "Rockster160") }
  let(:item) do
    agenda.agenda_items.create!(
      kind: :event,
      name: "Texas Roadhouse",
      start_at: Time.zone.local(2026, 6, 18, 20, 0),
      end_at:   Time.zone.local(2026, 6, 18, 22, 0),
      location: "Texas Roadhouse",
      arrive_early_minutes: 10,
      metadata: {
        "travel_minutes" => 25,
        "travel"         => { "location_address" => "11593 4000 W, South Jordan, UT 84009, USA" },
      },
    )
  end

  def fragment(html)
    # Wrap the partial output in a synthetic tag so Nokogiri can parse
    # the bare `data-*` attr blob the partial emits.
    Nokogiri::HTML.fragment("<div #{html}></div>").at_css("div")
  end

  before { sign_in user if respond_to?(:sign_in) }

  it "emits every attribute agenda.js reads via dataset" do
    rendered = render(partial: "agenda_items/data_attrs", locals: { item: item, editable: true })
    el = fragment(rendered)

    {
      "data-item-id"             => item.display_id,
      "data-item-url"            => "/agenda_items/#{item.display_id}",
      "data-phantom"             => "false",
      "data-recurring"           => "false",
      "data-agenda-schedule-id"  => "",
      "data-detached"            => "false",
      "data-kind"                => "event",
      "data-agenda-id"           => item.agenda_id.to_s,
      "data-agenda-name"         => "Rockster160",
      "data-all-day"             => "false",
      "data-name"                => "Texas Roadhouse",
      "data-location"            => "Texas Roadhouse",
      "data-resolved-address"    => "11593 4000 W, South Jordan, UT 84009, USA",
      "data-arrive-early-minutes" => "10",
      "data-travel-minutes"      => "25",
      "data-start-at"            => item.start_at.to_i.to_s,
      "data-end-at"              => item.end_at.to_i.to_s,
    }.each do |attr, expected|
      expect(el[attr]).to eq(expected), "expected #{attr}=#{expected.inspect}, got #{el[attr].inspect}"
    end
  end

  it "emits `data-readonly` (no value) when editable is false" do
    rendered = render(partial: "agenda_items/data_attrs", locals: { item: item, editable: false })
    expect(rendered).to match(/\bdata-readonly\b/)
  end

  it "omits `data-readonly` when editable is true" do
    rendered = render(partial: "agenda_items/data_attrs", locals: { item: item, editable: true })
    expect(rendered).not_to match(/\bdata-readonly\b/)
  end

  it "lets all_day_value override the item's all_day? (cal_month hardcoded loops)" do
    rendered = render(partial: "agenda_items/data_attrs",
      locals: { item: item, editable: true, all_day_value: true })
    expect(fragment(rendered)["data-all-day"]).to eq("true")
  end

  it "renders the agenda-item-data marker for JS hooks across all four views" do
    # The marker class is on the wrapper element in calendar/cal_month and
    # on .agenda-item in _item — verify the partial doesn't accidentally
    # introduce its own element that would shadow those hooks.
    rendered = render(partial: "agenda_items/data_attrs", locals: { item: item, editable: true })
    # Should be a string of attributes only — no element tags.
    expect(rendered).not_to match(/<[a-z]/i)
  end
end
