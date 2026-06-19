require "rails_helper"

# Pin the structural shape of the `agenda-item-template` `<template>`
# element that `agenda_item_renderer.js` clones on store changes. The JS
# fills text + attributes into specific child selectors — every selector
# below MUST exist as a single node in the cloned tree, otherwise the
# renderer silently no-ops on that field.
RSpec.describe "agenda_items/_template" do
  before { render(template: "agenda_items/_template") }

  it "renders the <template> wrapper with the id JS looks up" do
    expect(rendered).to include('<template id="agenda-item-template">')
  end

  it "includes the root .agenda-item div the renderer clones" do
    doc = Nokogiri::HTML.fragment(rendered)
    inner = doc.at_css("template").inner_html
    body = Nokogiri::HTML.fragment(inner)
    expect(body.at_css(".agenda-item")).to be_present
  end

  it "exposes every selector the renderer fills or removes" do
    doc = Nokogiri::HTML.fragment(rendered)
    body = Nokogiri::HTML.fragment(doc.at_css("template").inner_html)
    %w[
      .agenda-item-check-zone
      .agenda-item-check
      .agenda-item-body
      .agenda-item-time
      .agenda-item-name
      .agenda-item-loc
      .agenda-item-loc-text
      .agenda-item-travel
      .agenda-item-travel-leave
      .agenda-item-travel-arrive-icon
      .agenda-item-travel-arrive-text
      .agenda-item-travel-car-icon
      .agenda-item-travel-car-text
      .agenda-item-travel-plus
      .agenda-item-rsvp-slot
      .agenda-item-rsvp-slot .needs-response
      .agenda-item-rsvp-slot .declined
      .agenda-item-recurring-badge
      .agenda-item-edit-slot
      .agenda-item-edit
    ].each do |selector|
      expect(body.at_css(selector)).to be_present, "expected template to expose #{selector}"
    end
  end

  it "keeps time spans wired for data-time-hydrate (JS fills epoch later)" do
    doc = Nokogiri::HTML.fragment(rendered)
    body = Nokogiri::HTML.fragment(doc.at_css("template").inner_html)
    expect(body.at_css(".agenda-item-time")["data-time-hydrate"]).to eq("")
    expect(body.at_css(".agenda-item-travel-leave")["data-time-hydrate"]).to eq("")
    expect(body.at_css(".agenda-item-travel-leave")["data-format"]).to eq("cal")
    expect(body.at_css(".agenda-item-travel-leave")["data-prefix"]).to eq("→")
  end
end
