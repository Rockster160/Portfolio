require "rails_helper"

RSpec.describe "GPT presets and secrets", type: :request do
  let(:user) { create(:user) }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  it "renders the preset list, new, and edit pages" do
    preset = user.gpt_presets.create!(name: "Calories", instructions: "Estimate calories.")

    get jil_gpt_presets_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Calories")

    get new_jil_gpt_preset_path
    expect(response).to have_http_status(:ok)

    get edit_jil_gpt_preset_path(preset)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Estimate calories.")
  end

  it "creates, updates, and deletes a preset" do
    post jil_gpt_presets_path, params: { gpt_preset: { name: "Summarize", instructions: "Be short." } }
    preset = user.gpt_presets.named("summarize")
    expect(preset.instructions).to eq("Be short.")

    patch jil_gpt_preset_path(preset), params: { gpt_preset: { instructions: "Be shorter." } }
    expect(preset.reload.instructions).to eq("Be shorter.")

    delete jil_gpt_preset_path(preset)
    expect(user.gpt_presets.count).to eq(0)
  end

  it "refuses a second preset with the same name in any case" do
    user.gpt_presets.create!(name: "Calories", instructions: "x")

    post jil_gpt_presets_path, params: { gpt_preset: { name: "calories", instructions: "y" } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(user.gpt_presets.count).to eq(1)
  end

  it "saves a secret, replaces it by name, and never shows more than its last four characters" do
    post jil_secrets_path, params: { name: "OpenAI", value: " sk-secret-abcd1234 " }
    post jil_secrets_path, params: { name: "openai", value: "sk-secret-wxyz9876" }

    expect(user.secrets.count).to eq(1)
    expect(user.secrets.named("OpenAI").value).to eq("sk-secret-wxyz9876")

    get jil_secrets_path
    expect(response.body).to include("OpenAI", "…9876")
    expect(response.body).not_to include("sk-secret")

    delete jil_secret_path(user.secrets.first)
    expect(user.secrets.count).to eq(0)
  end

  it "renames a secret and rolls its value only when a new one is given" do
    secret = user.secrets.create!(name: "OpenAI", value: "sk-secret-abcd1234")

    get edit_jil_secret_path(secret)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("OpenAI", "…1234")
    expect(response.body).not_to include("sk-secret")

    patch jil_secret_path(secret), params: { name: "OpenAI Work", value: " " }
    expect(secret.reload.name).to eq("OpenAI Work")
    expect(secret.value).to eq("sk-secret-abcd1234")

    patch jil_secret_path(secret), params: { name: "OpenAI Work", value: " sk-secret-wxyz9876 " }
    expect(secret.reload.value).to eq("sk-secret-wxyz9876")
  end

  it "refuses to rename a secret onto another one's name" do
    user.secrets.create!(name: "OpenAI", value: "x")
    secret = user.secrets.create!(name: "Slack", value: "y")

    patch jil_secret_path(secret), params: { name: "openai", value: "" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(secret.reload.name).to eq("Slack")
  end

  it "keeps password managers off the secret form" do
    get jil_secrets_path

    page = Nokogiri::HTML(response.body)
    [page.at_css("input[name=name]"), page.at_css("input[name=value]")].each { |input|
      expect(input["data-1p-ignore"]).to eq("true")
      expect(input["autocomplete"]).to eq("off")
    }
    expect(page.at_css("input[name=value]")["type"]).to eq("text")
    expect(page.at_css("input[name=value]")["class"]).to eq("text-security")
    expect(page.css("input[type=password]")).to be_empty
  end

  it "only reaches the signed-in user's own records" do
    other = create(:user)
    preset = other.gpt_presets.create!(name: "Theirs", instructions: "x")
    secret = other.secrets.create!(name: "Theirs", value: "x")

    get edit_jil_gpt_preset_path(preset)
    expect(response).to have_http_status(:redirect)

    get edit_jil_secret_path(secret)
    expect(response).to have_http_status(:redirect)

    patch jil_secret_path(secret), params: { name: "Mine", value: "y" }
    delete jil_secret_path(secret)
    expect(secret.reload.name).to eq("Theirs")
  end
end
