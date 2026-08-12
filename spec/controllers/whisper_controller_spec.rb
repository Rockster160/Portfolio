require "rails_helper"

RSpec.describe WhisperController, type: :controller do
  render_views

  # The controller gates on literal ids, so the fixtures have to carry them.
  let(:owner) { User.find_by(id: 1) || create(:user, id: 1) }
  let(:caretaker) { User.find_by(id: 4) || create(:user, id: 4) }
  let(:stranger) { create(:user) }

  before do
    list = List.find_by(id: 360) || create(:list, id: 360, name: "Whisper TODO")
    UserList.find_or_create_by!(list: list, user: owner)
  end

  def button_task(monitor, name)
    Task.create!(
      user:     owner,
      name:     name,
      listener: "monitor::whisper-btn-#{monitor}",
      code:     "x = String.new(\"noop\")::String\n",
    )
  end

  def rendered_monitors
    response.body.scan(/data-monitor="([^"]+)"/).flatten
  end

  describe "GET #show" do
    it "is successful with no buttons set up yet" do
      sign_in owner
      get :show

      expect(response).to be_successful
      expect(rendered_monitors).to eq([])
    end

    # The water button is created in prod by lib/scripts/whisper_water_button.rb,
    # so its id isn't knowable here — the page keys off the monitor listener and
    # renders in BUTTON_MONITORS order regardless of id order.
    it "renders the button tasks in BUTTON_MONITORS order, not id order" do
      described_class::BUTTON_MONITORS.reverse.each_with_index { |monitor, idx|
        button_task(monitor, "Button #{idx}")
      }

      sign_in owner
      get :show

      expect(rendered_monitors)
        .to eq(described_class::BUTTON_MONITORS.map { |m| "whisper-btn-#{m}" })
    end

    # There are other `monitor::whisper-btn-*` tasks in prod (whisper-btn-walk,
    # -stay, -call...) that were never on the page.
    it "ignores whisper-btn tasks that aren't in the allowlist" do
      button_task(:water, "Whisper Water")
      button_task(:walk, "Whisper Walk")

      sign_in owner
      get :show

      expect(rendered_monitors).to eq(["whisper-btn-water"])
    end

    it "skips buttons that haven't been created yet" do
      button_task(:water, "Whisper Water")

      sign_in owner
      get :show

      expect(rendered_monitors).to eq(["whisper-btn-water"])
    end

    it "shows a caretaker the page without the owner's buttons" do
      button_task(:water, "Whisper Water")

      sign_in caretaker
      get :show

      expect(response).to be_successful
      expect(rendered_monitors).to eq([])
    end

    it "forbids anyone else" do
      sign_in stranger
      get :show

      expect(response).to have_http_status(:forbidden)
    end
  end
end
