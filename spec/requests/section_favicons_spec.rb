require "rails_helper"

RSpec.describe "Section favicons", type: :request do
  let(:user) { User.me }
  let(:password) { "password123" }

  before do
    user.update!(password: password, password_confirmation: password)
    post "/login", params: { user: { username: user.username, password: password } }
  end

  def icon_dir
    response.body[%r{rel="shortcut icon" href="(/[a-z_]+)/favicon\.ico}, 1]
  end

  it "gives Jil pages the Jil icon" do
    ["/jil", "/jil/executions", "/jil/secrets", "/jil/health"].each do |path|
      get path
      expect(response).to have_http_status(:ok), path
      expect(icon_dir).to eq("/jil_favicon"), path
    end
  end

  it "gives the list builder index and form the pantry icon" do
    ["/jarvis/list_builders", "/jarvis/list_builders/new"].each do |path|
      get path
      expect(response).to have_http_status(:ok), path
      expect(icon_dir).to eq(ListBuilder.favicon_dir), path
    end
  end

  it "gives the meal builder index and form the plate icon" do
    ["/jarvis/meal_builders", "/jarvis/meal_builders/new"].each do |path|
      get path
      expect(response).to have_http_status(:ok), path
      expect(icon_dir).to eq(MealBuilder.favicon_dir), path
    end
  end

  it "gives the random page the dice icon" do
    get "/random"
    expect(response).to have_http_status(:ok)
    expect(icon_dir).to eq("/random_favicon")
    expect(response.body).to include("/random_favicon/apple-touch-icon.png")
  end

  it "keeps the default icon elsewhere" do
    get "/quests"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("favicon/apple-touch-icon")
    expect(icon_dir).to be_nil
  end
end
