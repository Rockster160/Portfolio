require "rails_helper"

# The errors page: grouped by default, because the question is almost never
# "what happened at 3:04" but "what is going wrong, how often, and for whom".
RSpec.describe "System errors page", type: :request do
  let(:user) { User.me }

  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  before { sign_in }

  # Nobody else's business: the route is inside the same MeConstraint block as
  # every other system page, and `require_me` answers 404 on the controller for
  # anyone who gets past it. Neither is this page's to assert.

  def record(section: "sync", message: "timed out", user_for: nil, channel: nil, at: Time.current)
    exception = StandardError.new(message).tap { |e| e.set_backtrace(["app/service/sync.rb:9"]) }
    travel_to(at) {
      ErrorReport.record!(section: section, exception: exception, user: user_for, channel: channel)
    }
  end

  describe "the list" do
    it "shows one row per distinct failure with its count" do
      3.times { |i| record(message: "no item #{i}") }

      get system_errors_path

      expect(response.body).to include("sync")
      expect(response.body).to include("3×")
    end

    it "separates failures that aren't the same one" do
      record(section: "sync")
      record(section: "turn", message: "something else")

      get system_errors_path

      expect(response.body).to include("sync", "turn")
    end

    it "names who each one happened for" do
      record(user_for: user)

      get system_errors_path

      expect(response.body).to include("#{user.first_name} (##{user.id})")
    end

    it "says when a failure was never announced" do
      record
      get system_errors_path

      expect(response.body).to include("never announced")
    end

    # The chips list every section in the window whichever one is picked, so
    # what the filter changes is the ROWS - checked here by their messages.
    it "filters to the ones nothing announced" do
      record(section: "quiet-one", message: "nobody saw this")
      record(section: "announced-one", message: "this one pinged", channel: "#zygy-alerts")

      get system_errors_path(unannounced: 1)

      expect(response.body).to include("nobody saw this")
      expect(response.body).not_to include("this one pinged")
    end

    it "filters to one section" do
      record(section: "sync", message: "the sync one")
      record(section: "turn", message: "the turn one")

      get system_errors_path(section: "turn")

      expect(response.body).to include("the turn one")
      expect(response.body).not_to include("the sync one")
    end

    it "keeps to the window it was asked for" do
      record(section: "ancient", at: 20.days.ago)

      get system_errors_path(hours: 24)

      expect(response.body).not_to include("ancient")
      expect(response.body).to include("Quiet is the right answer")
    end

    it "reaches back when asked to" do
      record(section: "ancient", at: 20.days.ago)

      get system_errors_path(hours: 24 * 30)

      expect(response.body).to include("ancient")
    end
  end

  it "is reachable from the system index, with today's count on it" do
    record
    record(section: "turn", message: "another")

    get system_path

    expect(response.body).to include(system_errors_path)
    expect(response.body).to include("Errors")
  end

  describe "one error" do
    it "shows the whole row, which is what an alert links to" do
      row = record(user_for: user, message: "timed out reaching Google")

      get system_error_path(id: row.id)

      expect(response.body).to include("timed out reaching Google")
      expect(response.body).to include("app/service/sync.rb:9")
      expect(response.body).to include("#{user.first_name} (##{user.id})")
    end

    it "lists the earlier occurrences of the same failure" do
      first = record(message: "no item 1", at: 2.hours.ago)
      later = record(message: "no item 2")

      get system_error_path(id: later.id)

      expect(response.body).to include(system_error_path(id: first.id))
    end
  end
end
