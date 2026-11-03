require "rails_helper"

RSpec.describe "Expression Lab", type: :request do
  # Behind MeConstraint like the rest of /system, so it only loads for the owner.
  let(:user) { User.me }

  before { post login_path, params: { user: { username: user.username, password: "password" } } }

  it "is linked from the system index" do
    get system_path
    expect(response.body).to include(system_expressions_path)
  end

  it "renders every companion, its mood values, and the vibe slider data", :aggregate_failures do
    get system_expressions_path

    expect(response).to have_http_status(:ok)
    Buddy::Faces.index.each_key do |theme|
      expect(response.body).to include(Buddy::Themes.name_for(theme)),
        "#{theme} is missing from the lab"
    end

    # Pick a real row off the constant rather than hardcoding one, so this stays
    # true as the tables change.
    theme, faces = Buddy::Faces.index.first
    name, vals   = faces.first
    expect(response.body).to include(name.to_s.tr("_", " "))
    Buddy::Faces::AXES.each do |axis|
      expect(response.body).to include(format("%.2f", vals[axis].to_f)),
        "#{theme}/#{name} #{axis} value is not shown"
    end

    raw = response.body[/data-exlab-vibe-data="([^"]*)"/, 1]
    vibe = JSON.parse(CGI.unescapeHTML(raw))
    expect(vibe["softness"]).to eq(Buddy::Faces::SOFTNESS)
    expect(vibe["pets"]["bloom"]["pounce"]).to include("play" => 0.85, "reach" => 0.17)
    expect(vibe["pets"]["bloom"]["hiding"]["url"]).to include("face_hiding")
  end
end
