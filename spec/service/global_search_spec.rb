require "rails_helper"

RSpec.describe GlobalSearch do
  let(:user) { create(:user) }
  let(:other) { create(:user) }
  let(:routes) { Rails.application.routes.url_helpers }
  let(:results) { search("zephyr") }

  let!(:records) {
    household = ChoreHousehold.create!(name: "Mine", owner_user: user)
    user.update!(chore_household_id: household.id)
    other_household = ChoreHousehold.create!(name: "Theirs", owner_user: other)
    other.update!(chore_household_id: other_household.id)

    list = create(:list, name: "Zephyr groceries", user: user)
    shared_list = create(:list, name: "Zephyr shared trip", user: other)
    create(:user_list, user: user, list: shared_list, is_owner: false)
    timer_page = create(:timer_page, user: user, name: "Zephyr board", slug: "zephyr-board")
    shared_page = create(:page, user: other, name: "Zephyr shared notes")
    SharedPage.create!(user: user, page: shared_page)

    {
      list:        list,
      shared_list: shared_list,
      items:       Array.new(3) { |i| create(:list_item, list: list, name: "Zephyr milk #{i}") },
      chore:       create(:chore, created_by_user: user, chore_household: household, name: "Zephyr litter"),
      page:        create(:page, user: user, name: "Zephyr notes"),
      shared_page: shared_page,
      timer_page:  timer_page,
      timer:       create(:timer, user: user, name: "Zephyr tea", timer_page: timer_page),
      loose_timer: create(:timer, user: user, name: "Zephyr nap"),
      email:       email_for(user, "Zephyr invoice"),
      stash:       BuddyMemory.create!(user: user, kind: :stash, content: "zephyr seed packets"),
      memory:      BuddyMemory.create!(user: user, kind: :concept, content: "zephyr is the cat"),
      contact:     user.contacts.create!(name: "Zephyr", last_name: "Jones"),
      box:         create(:box, user: user, name: "Zephyr bin"),
    }
  }

  let!(:others) {
    other_list = create(:list, name: "Zephyr private", user: other)
    other_household = ChoreHousehold.find(other.chore_household_id)

    {
      list:    other_list,
      item:    create(:list_item, list: other_list, name: "Zephyr secret item"),
      chore:   create(:chore, created_by_user: other, chore_household: other_household, name: "Zephyr theirs"),
      page:    create(:page, user: other, name: "Zephyr private page"),
      timer:   create(:timer, user: other, name: "Zephyr their tea"),
      tpage:   create(:timer_page, user: other, name: "Zephyr their board"),
      email:   email_for(other, "Zephyr their invoice"),
      stash:   BuddyMemory.create!(user: other, kind: :stash, content: "zephyr their seeds"),
      contact: other.contacts.create!(name: "Zephyr Theirs"),
      box:     create(:box, user: other, name: "Zephyr their bin"),
    }
  }

  before { allow(user).to receive(:me?).and_return(true) }

  def email_for(owner, subject)
    Email.create!(
      user:               owner,
      mail_id:            "gs-#{SecureRandom.hex(4)}",
      timestamp:          1.hour.ago,
      direction:          :inbound,
      inbound_mailboxes:  [{ address: "me@example.com" }],
      outbound_mailboxes: [{ address: "sender@example.com" }],
      subject:            subject,
      blurb:              "",
    )
  end

  def url(path)
    Buddy::AppPages.url_for(path)
  end

  def search(query, limit: GlobalSearch::PER_GROUP)
    described_class.call(user, query, limit: limit)
  end

  def group(results, name)
    results.find { |g| g[:group] == name }&.dig(:results) || []
  end

  it "finds each area's record and links to its own page" do
    expect(group(results, :lists).pluck(:id, :url)).to contain_exactly(
      [records[:list].id, url(routes.list_path(records[:list]))],
      [records[:shared_list].id, url(routes.list_path(records[:shared_list]))],
    )
    expect(group(results, :list_items).pluck(:id)).to match_array(records[:items].map(&:id))
    expect(group(results, :list_items).pluck(:url).uniq).to eq([url(routes.list_path(records[:list]))])
    expect(group(results, :chores).pluck(:id, :url)).to eq(
      [[records[:chore].id, url(routes.chore_routes_edit_path(records[:chore]))]],
    )
    expect(group(results, :pages).pluck(:id)).to contain_exactly(records[:page].id, records[:shared_page].id)
    expect(group(results, :timer_pages).pluck(:id, :url)).to eq(
      [[records[:timer_page].id, url(routes.timer_page_path("zephyr-board"))]],
    )
    expect(group(results, :timers).pluck(:id, :url)).to contain_exactly(
      [records[:timer].id, url(routes.timer_page_path("zephyr-board"))],
      [records[:loose_timer].id, url(routes.timers_path)],
    )
    expect(group(results, :emails).pluck(:id, :url)).to eq(
      [[records[:email].id, url(routes.email_path(records[:email]))]],
    )
    expect(group(results, :stash).pluck(:id)).to eq([records[:stash].id])
    expect(group(results, :memories).pluck(:id)).to eq([records[:memory].id])
    expect(group(results, :contacts).pluck(:id, :url)).to eq(
      [[records[:contact].id, url(routes.edit_contact_path(records[:contact]))]],
    )
    expect(group(results, :boxes).pluck(:id, :url)).to eq(
      [[records[:box].param_key, url("/b/#{records[:box].param_key}")]],
    )
  end

  it "uses symbols for groups and icons" do
    hits = results.flat_map { |g| g[:results] }
    expect(results.pluck(:group)).to all(be_a(Symbol))
    expect(hits.pluck(:icon)).to all(be_a(Symbol))
  end

  it "never returns another user's private records" do
    hits = results.flat_map { |g| g[:results] }
    found = hits.map { |hit| [hit[:group], hit[:id]] }

    expect(found).not_to include(
      [:lists, others[:list].id],
      [:list_items, others[:item].id],
      [:chores, others[:chore].id],
      [:pages, others[:page].id],
      [:timers, others[:timer].id],
      [:timer_pages, others[:tpage].id],
      [:emails, others[:email].id],
      [:stash, others[:stash].id],
      [:contacts, others[:contact].id],
      [:boxes, others[:box].param_key],
    )
  end

  it "leaves memories out for anyone without the page that shows them" do
    allow(user).to receive(:me?).and_return(false)

    expect(group(results, :stash)).to be_empty
    expect(group(results, :memories)).to be_empty
  end

  it "returns nothing for a blank query" do
    expect(search("")).to eq([])
    expect(search("   ")).to eq([])
    expect(search(nil)).to eq([])
    expect(described_class.call(nil, "zephyr")).to eq([])
  end

  it "holds the per-group limit" do
    limited = search("zephyr", limit: 2)

    expect(limited.map { |g| g[:results].length }).to all(be <= 2)
    expect(group(limited, :list_items).length).to eq(2)
  end

  it "ranks the closest name first" do
    exact = create(:list, name: "Zephyr", user: user)

    expect(group(search("zephyr"), :lists).first[:id]).to eq(exact.id)
  end

  it "treats LIKE wildcards as plain text" do
    expect(search("%")).to eq([])
  end
end
