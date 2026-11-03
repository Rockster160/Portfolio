require "rails_helper"

# The `agenda-item-template` `<template>` that `agenda_item_renderer.js` clones.
# The JS fills text + attributes into specific child selectors, and silently
# no-ops on any that is missing.
RSpec.describe "agenda_items/_template" do
  it "exposes the root and every selector the renderer fills or removes", :aggregate_failures do
    render(template: "agenda_items/_template")

    template = Nokogiri::HTML.fragment(rendered).at_css("template#agenda-item-template")
    expect(template).to be_present
    body = Nokogiri::HTML.fragment(template.inner_html)

    %w[
      .agenda-item
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
      .agenda-item-rsvp-slot\ .needs-response
      .agenda-item-rsvp-slot\ .declined
      .agenda-item-recurring-badge
      .agenda-item-edit-slot
      .agenda-item-edit
    ].each do |selector|
      expect(body.at_css(selector)).to be_present, "expected template to expose #{selector}"
    end

    expect(body.at_css(".agenda-item-time")["data-time-hydrate"]).to eq("")
    leave = body.at_css(".agenda-item-travel-leave")
    expect(leave["data-time-hydrate"]).to eq("")
    expect(leave["data-format"]).to eq("cal")
  end
end
