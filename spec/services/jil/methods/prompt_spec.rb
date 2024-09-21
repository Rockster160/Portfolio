RSpec.describe Jil::Methods::Hash do
  include ActiveJob::TestHelper
  let(:execute) { Jil::Executor.call(user, code, input_data) }
  let(:user) { User.me }
  let(:code) {
    <<-JIL
      wa0d7 = Prompt.create("Good morning! How was your sleep?", "", {
        t33bc = PromptQuestion.scale("Sleep Quality", 0, 100, 50)::PromptQuestion
        s5a6a = PromptQuestion.scale("Sleep Length", 0, 100, 50)::PromptQuestion
      }, false)::Prompt
    JIL
  }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  # [Prompt]
  #   #find(String|Numeric)
  #   #all("complete?" Boolean(false))::Array
  #   #create("Title" TAB String BR "Params" TAB Hash? BR "Data" TAB Hash? BR "Questions" content(PromptQuestion))
  #   .update("Title" TAB String BR "Params" TAB Hash? BR "Data" TAB Hash? BR "Questions" content(PromptQuestion))::Boolean
  #   .destroy::Boolean
  #   .deliver::Boolean
  # [PromptQuestion]
  #   #text(String:"Question Text" BR "Default" String)
  #   #checkbox(String:"Question Text" BR "Default" Boolean)
  #   #choices(String:"Question Text" content(String))
  #   #scale(String:"Question Text" BR Numeric?:"Min" Numeric?:"Max" Numeric?:"Default")

  context "#create" do
    it "creates a PromptQuestion" do
      expect_successful_jil
      prompt = JilPrompt.last
      expect(ctx.dig(:vars, :t33bc)).to match_hash({
        class: :PromptQuestion,
        value: {
          type: :scale,
          question: "Sleep Quality",
          min: 0,
          max: 100,
          default: 50,
        }
      })
      expect(ctx.dig(:vars, :wa0d7)).to match_hash({
        class: :Prompt,
        value: {
          id: prompt.id,
          question: "Good morning! How was your sleep?",
          params: nil,
          options: [
            {
              type: "scale",
              question: "Sleep Quality",
              min: 0,
              max: 100,
              default: 50
            }, {
              type: "scale",
              question: "Sleep Length",
              min: 0,
              max: 100,
              default: 50,
            },
          ],
          response: nil,
          task: nil,
          url: "http://localhost:3141/prompts/#{prompt.id}",
        },
      })
      expect(ctx[:output]).to eq([])
    end
  end
end
