require "rails_helper"

RSpec.describe "Prompt search questions", type: :request do
  let(:user) { create(:user) }
  let!(:dragon) { user.action_events.create!(name: "Print", notes: "Dragon", timestamp: 1.day.ago) }
  let!(:benchy) { user.action_events.create!(name: "Print", notes: "Benchy", timestamp: 1.hour.ago) }
  let!(:fruit) { user.action_events.create!(name: "Food", notes: "Dragon fruit", timestamp: 1.hour.ago) }

  def sign_in
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  before { allow(::Jil).to receive(:trigger).and_return(true) }

  describe "the box's search" do
    it "answers with the matches drawn from the question's templates" do
      sign_in
      get search_prompts_path(query: "action_events:print", term: "dragon", title: "**{notes}**"),
        headers: { "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      results = response.parsed_body["results"]
      expect(results.pluck("id")).to eq([dragon.id])
      expect(results.first).to include("title" => "Dragon", "title_html" => "<strong>Dragon</strong>")
    end
  end

  describe "answering on the page" do
    let(:prompt) {
      user.prompts.create!(question: "Printed", answer_type: :single, options: [
        { "type" => "search", "question" => "Which?", "query" => "action_events:print", "title" => "{notes}" },
        { "type" => "search", "question" => "Also", "query" => "action_events:print", "multiple" => true },
      ])
    }

    it "renders a search box carrying its settings" do
      sign_in
      get prompt_path(prompt)

      expect(response.body).to include("prompt-search-field", "action_events:print")
    end

    it "saves each pick as its id and the record's own title" do
      sign_in
      patch prompt_path(prompt), params: {
        prompt: {
          response: {
            "Which?" => { "id" => dragon.id, "title" => "made up" },
            "Also"   => [{ "id" => benchy.id, "title" => "x" }, { "id" => dragon.id, "title" => "y" }],
          },
        },
      }

      expect(prompt.reload.response).to eq(
        "Which?" => { "id" => dragon.id, "title" => "Dragon" },
        "Also"   => [{ "id" => benchy.id, "title" => "Print" }, { "id" => dragon.id, "title" => "Print" }],
      )
    end

    it "drops a pick the question would never have offered" do
      sign_in
      patch prompt_path(prompt), params: {
        prompt: { response: { "Which?" => { "id" => fruit.id, "title" => "Dragon fruit" }, "Also" => "" } },
      }

      expect(prompt.reload.response).to eq("Which?" => nil, "Also" => [])
    end
  end
end
