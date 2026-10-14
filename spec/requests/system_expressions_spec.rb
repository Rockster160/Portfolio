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
