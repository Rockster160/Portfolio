require "rails_helper"

RSpec.describe FaeController, type: :controller do
  render_views

  let(:user) { create(:user) }

  before { sign_in user }

  def button_task(monitor, name)
    Task.create!(
      user:     user,
      name:     name,
      listener: "monitor::fae-btn-#{monitor}",
      code:     "x = String.new(\"noop\")::String\n",
    )
  end

  def rendered_monitors
    response.body.scan(/data-monitor="([^"]+)"/).flatten
  end

  # The row is grouped by person rather than by chore — his four, then hers.
  it "lists all of his buttons ahead of all of hers" do
    mine, hers = described_class::BUTTON_MONITORS.partition { |m| m.end_with?("-mine") }

    expect(mine.size).to eq(4)
    expect(hers.size).to eq(4)
    expect(described_class::BUTTON_MONITORS).to eq(mine + hers)
  end

  describe "GET #show" do
    it "is successful with no buttons set up yet" do
      get :show
      expect(response).to be_successful
      expect(rendered_monitors).to eq([])
    end

    # The buttons are created in prod by lib/scripts/fae_chore_buttons.rb, so
    # their ids aren't knowable here — the page keys off the monitor listener
    # and renders them in BUTTON_MONITORS order regardless of id order.
    it "renders the button tasks in BUTTON_MONITORS order, not id order" do
      described_class::BUTTON_MONITORS.reverse.each_with_index { |monitor, idx|
        button_task(monitor, "Button #{idx}")
      }

      get :show
      expect(rendered_monitors)
        .to eq(described_class::BUTTON_MONITORS.map { |m| "fae-btn-#{m}" })
    end

    it "ignores monitor tasks that aren't Fae buttons" do
      button_task(:"laundry-mine", "Fae Laundry (Mine)")
      Task.create!(user: user, name: "Other", listener: "monitor::something-else", code: "")

      get :show
      expect(rendered_monitors).to eq(["fae-btn-laundry-mine"])
    end

    it "skips buttons that haven't been created yet" do
      button_task(:"food-hers", "Fae Fed (Hers)")

      get :show
      expect(rendered_monitors).to eq(["fae-btn-food-hers"])
    end
  end
end
