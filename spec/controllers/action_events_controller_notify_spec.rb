require "rails_helper"

# The events page mutates events too, so it owes the same side effects as Jil
# and Buddy. It used to skip ActionEventNotifier entirely, and a drink deleted
# here stayed on the dashboard's Caffeine bar.
RSpec.describe ActionEventsController, type: :controller do
  let(:user) { create(:user) }

  before do
    sign_in user
    allow(::Jil).to receive(:trigger)
    allow(::ActionEventBroadcastWorker).to receive(:perform_async)
    allow(::RecentEventsBroadcast).to receive(:call)
    allow(::SpendingHealth).to receive(:refresh!)
  end

  it "republishes the spending cell when a drink is deleted" do
    drink = ActionEvent.create!(
      user: user, name: "Drink", timestamp: Time.current, data: { "Caffeine" => 200 },
    )

    delete :destroy, params: { id: drink.id }

    expect(ActionEvent.exists?(drink.id)).to be(false)
    expect(::SpendingHealth).to have_received(:refresh!)
    expect(::Jil).to have_received(:trigger).with(user, :event, anything, anything)
  end

  it "leaves the spending cell alone for an event with no caffeine" do
    event = ActionEvent.create!(user: user, name: "Pullups", timestamp: Time.current)

    delete :destroy, params: { id: event.id }

    expect(::SpendingHealth).not_to have_received(:refresh!)
  end

  it "republishes the spending cell when a drink is added" do
    post :create, params: { name: "Drink", data: '{"Caffeine": 200}' }, format: :json

    expect(response).to have_http_status(:ok)
    expect(::SpendingHealth).to have_received(:refresh!)
  end

  it "only edits the signed-in user's events" do
    theirs = ActionEvent.create!(user: create(:user), name: "Drink", timestamp: Time.current)

    patch :update, params: { id: theirs.id, name: "Mine now" }, format: :json

    expect(theirs.reload.name).to eq("Drink")
  end
end
