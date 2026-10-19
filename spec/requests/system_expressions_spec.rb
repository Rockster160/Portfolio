require "rails_helper"

RSpec.describe "Expression Lab", type: :request do
  # Behind MeConstraint like the rest of /system, so it only loads for the owner.
  let(:user) { User.me }

  before { post login_path, params: { user: { username: user.username, password: "password" } } }

  it "is linked from the system index" do
    get system_path
    expect(response.body).to include(system_expressions_path)
    expect(response.body).to include("Expression Lab")
  end

  it "renders every companion that has a mood map" do
    get system_expressions_path

    expect(response).to have_http_status(:ok)
    Buddy::Faces.index.each_key do |theme|
      expect(response.body).to include(Buddy::Themes.name_for(theme)),
        "#{theme} is missing from the lab"
    end
  end

  it "folds the wave into the System group and draws a blank slot for a missing system pose" do
    get system_expressions_path

    # The wave is a system slot now (tagged a gesture), not a mood — a pet with
    # the art (e.g. Cobalt) shows it; one without (Tiko) shows a blank slot
    # rather than hiding the slot, so the gaps in a set are visible.
    expect(response.body).to include(">gesture<")
    expect(response.body).to include("no pose")
  end

  it "shows a pose a pet only has art for, with no mood values" do
    get system_expressions_path

    mocha = response.body[%r{data-exlab-pet="mocha".*?</section>}m]
    expect(mocha).to include("Mocha — clock")
    expect(mocha).to include("Worn on cue, never picked as a mood.")
  end

  it "carries every pet's mood table and the picker's tuning for the vibe sliders" do
    get system_expressions_path

    raw = response.body[/data-exlab-vibe-data="([^"]*)"/, 1]
    vibe = JSON.parse(CGI.unescapeHTML(raw))
    expect(vibe["softness"]).to eq(Buddy::Faces::SOFTNESS)
    expect(vibe["pets"]["bloom"]["pounce"]).to include("play" => 0.85, "reach" => 0.17)
    expect(vibe["pets"]["bloom"]["hiding"]["url"]).to include("face_hiding")
  end

  it "shows each expression's label and its mood values, read from the constants" do
    get system_expressions_path

    # Pick a real row off the constant rather than hardcoding one, so this stays
    # true as the tables change.
    theme, faces = Buddy::Faces.index.first
    name, vals   = faces.first

    expect(response.body).to include(name.to_s.tr("_", " "))
    Buddy::Faces::AXES.each do |axis|
      expect(response.body).to include(format("%.2f", vals[axis].to_f)),
        "#{theme}/#{name} #{axis} value is not shown"
    end
    expect(response.body).to include(format("%.2f", vals[:reach].to_f))
  end
end
