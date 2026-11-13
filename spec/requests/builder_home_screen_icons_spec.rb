require "rails_helper"

RSpec.describe "Builder home screen icons", type: :request do
  let(:user) { User.me }
  let(:password) { "password123" }
  let(:png) { "\x89PNG\r\n\x1A\n".b + ("pixels" * 10) }
  let(:data_url) { "data:image/png;base64,#{Base64.strict_encode64(png)}" }

  before do
    user.update!(password: password, password_confirmation: password)
    post "/login", params: { user: { username: user.username, password: password } }
  end

  shared_examples "an installable builder" do |key, path, description|
    let(:base) { "/jarvis/#{path}/#{builder.to_param}" }
    let(:param_key) { key }

    def install_path(name, token: builder.install_token)
      "#{base}/#{name}?t=#{token}"
    end

    def submit(fields)
      patch base, params: { param_key => { name: builder.name }.merge(fields) }
    end

    it "keeps the icon picked on the edit form and serves it, named and scoped to the builder" do
      submit(icon: "🥚", icon_color: "#224466", icon_data_url: data_url)
      expect(response).to redirect_to(base)
      builder.reload
      expect(builder).to have_attributes(icon: "🥚", icon_color: "#224466")
      expect(builder.icon_png.b).to eq(png)

      get base
      icon_url = response.body[%r{rel="apple-touch-icon" sizes="180x180" href="([^"]+)"}, 1]
      icon_url = CGI.unescapeHTML(icon_url)
      expect(icon_url).to start_with("#{base}/icon.png?t=")
      expect(response.body).to include("#{base}/manifest?t=", "content=\"#224466\"")

      get "/logout"
      get icon_url
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/png")
      expect(response.body.b).to eq(png)

      get install_path("manifest")
      manifest = ActiveSupport::JSON.decode(response.body)
      expect(manifest).to include(
        "name"        => builder.name,
        "start_url"   => "#{base}?source=pwa",
        "scope"       => base,
        "theme_color" => "#224466",
        "description" => "#{description}: #{builder.name}",
      )
      expect(manifest["icons"].pluck("src")).to all(eq(icon_url))
    end

    it "leaves the icon alone when the form is saved without touching it" do
      submit(icon: "🥚", icon_color: "#224466", icon_data_url: data_url)
      submit(name: "Renamed")
      expect(builder.reload).to have_attributes(name: "Renamed", icon: "🥚")
      expect(builder.icon_png.b).to eq(png)
    end

    it "goes back to the default icon when cleared" do
      submit(icon: "🥚", icon_color: "#224466", icon_data_url: data_url)
      submit(icon: "", icon_color: "", icon_data_url: "")
      expect(builder.reload).to have_attributes(icon: nil, icon_color: nil, icon_png: nil)

      get install_path("manifest")
      icons = ActiveSupport::JSON.decode(response.body)["icons"].pluck("src")
      expect(icons).to include("/favicon/android-chrome-512x512.png")
      get install_path("icon.png")
      expect(response).to have_http_status(:not_found)
    end

    it "refuses something that isn't a PNG" do
      gif = "data:image/png;base64,#{Base64.strict_encode64("GIF89a")}"
      submit(icon: "🥚", icon_data_url: gif)
      expect(builder.reload.icon_png).to be_nil
    end

    it "opens nothing without the builder's own token" do
      submit(icon: "🥚", icon_color: "#224466", icon_data_url: data_url)
      get "/logout"

      get "#{base}/manifest"
      expect(response).to have_http_status(:not_found)
      get install_path("icon.png", token: other.install_token)
      expect(response).to have_http_status(:not_found)
    end

    it "shows the picker on the edit form" do
      get "#{base}/edit"
      expect(response.body).to include("data-app-icon-form-field", "#{key}[icon_data_url]")
    end
  end

  describe "a list builder" do
    let(:list) { create(:list, user: user) }
    let(:builder) { user.list_builders.create!(name: "Pantry", list: list, items: []) }
    let(:other) { user.list_builders.create!(name: "Garage", list: list, items: []) }

    it_behaves_like "an installable builder", :list_builder, :list_builders, "List Builder"
  end

  describe "a meal builder" do
    let(:builder) { user.meal_builders.create!(name: "Breakfast", items: []) }
    let(:other) { user.meal_builders.create!(name: "Dinner", items: []) }

    it_behaves_like "an installable builder", :meal_builder, :meal_builders, "Meal Builder"

    it "keeps the PNG out of the builder's JSON" do
      builder.update!(icon: "🥚", icon_data_url: data_url)
      patch "/jarvis/meal_builders/#{builder.to_param}", params: { meal_builder: { name: "Breakfast" } }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key("icon_png")
      expect(response.parsed_body["icon"]).to eq("🥚")
    end
  end
end
