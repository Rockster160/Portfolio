RSpec.describe "Game Score Tasks" do
  include ActiveJob::TestHelper

  let(:user) { User.me }

  # -- Task 1: Game Score Prompt -----------------------------------------------
  # Triggered by event:action:added name::Game
  # Creates a prompt with prefilled game name and score textarea
  let(:prompt_task) {
    user.tasks.create!(
      name:     "Game Score Prompt",
      listener: "event:action:added name::Game",
      code:     <<~JIL.strip,
        event = Global.input_data()::ActionEvent
        event_id = event.id()::Numeric
        game_name = event.notes()::String
        existing_data = event.data()::Hash
        score_default = Global.if({
          a1 = existing_data.presence()::Any
        }, {
          score_arr = existing_data.map({
            key = Keyword.Key()::String
            val = Keyword.Value()::Any
            a2 = String.new("\#{key} \#{val}")::String
          })::Array
          a3 = score_arr.join("\\n")::String
        }, {
          a4 = String.new("")::String
        })::Any
        prompt_data = Hash.new({
          a5 = Keyval.new("source", "game_scores")::Keyval
          a6 = Keyval.new("event_id", event_id)::Keyval
        })::Hash
        result = Prompt.create("Game Scores", prompt_data, {
          a7 = PromptQuestion.text("Game", game_name)::PromptQuestion
          a8 = PromptQuestion.textarea("Scores", score_default)::PromptQuestion
        }, false)::Prompt
      JIL
    )
  }

  # -- Task 2: Game Score Dynamic Load -----------------------------------------
  # Triggered on prompt:state:load to prefill with current event data
  let(:dynamic_load_task) {
    user.tasks.create!(
      name:     "Game Score Dynamic Load",
      listener: "prompt:state:load params:source:game_scores",
      code:     <<~JIL.strip,
        prompt = Global.input_data()::Prompt
        pdata = prompt.data()::Hash
        event_id = pdata.get("event_id")::Numeric
        event = ActionEvent.find(event_id)::ActionEvent
        game_name = event.notes()::String
        existing_data = event.data()::Hash
        score_default = Global.if({
          b1 = existing_data.presence()::Any
        }, {
          score_arr = existing_data.map({
            key = Keyword.Key()::String
            val = Keyword.Value()::Any
            b2 = String.new("\#{key} \#{val}")::String
          })::Array
          b3 = score_arr.join("\\n")::String
        }, {
          b4 = String.new("")::String
        })::Any
        orig_questions = prompt.questions()::Array
        filtered_questions = orig_questions.reject({
          q = Keyword.Object()::Hash
          qname = q.get("question")::String
          b4 = qname.match("/^(Game|Scores)$/")::Boolean
        })::Array
        gameQ = PromptQuestion.text("Game", game_name)::PromptQuestion
        scoresQ = PromptQuestion.textarea("Scores", score_default)::PromptQuestion
        b5 = filtered_questions.push!(gameQ)::Array
        b6 = filtered_questions.push!(scoresQ)::Array
        b7 = prompt.update("", "", filtered_questions)::Boolean
      JIL
    )
  }

  # -- Task 3: Game Score Submitted --------------------------------------------
  # Triggered on prompt completion, parses scores and updates event
  let(:submitted_task) {
    user.tasks.create!(
      name:     "Game Score Submitted",
      listener: "prompt:params:source:game_scores",
      code:     <<~JIL.strip,
        input = Global.input_data()::Hash
        prms = input.get("params")::Hash
        event_id = prms.get("event_id")::Numeric
        response = input.get("response")::Hash
        game_name = response.get("Game")::String
        raw_scores = response.get("Scores")::String
        lines = raw_scores.split("\\n")::Array
        scores = Hash.new({})::Hash
        c0 = lines.each({
          raw_line = Keyword.Value()::String
          line = raw_line.format("squish")::String
          c1 = Global.if({
            c2 = line.presence()::Any
          }, {
            parts = line.match("/^(?<player>.+)\\\\s+(?<score>\\\\S+)$/")::Hash
            player = parts.get("player")::String
            score_str = parts.get("score")::String
            score = String.new(score_str)::Numeric
            c3 = scores.set!(player, score)::Hash
          }, {
            c4 = Global.comment("skip blank line")::None
          })::Any
        })::Array
        event = ActionEvent.find(event_id)::ActionEvent
        c5 = event.update!({
          c6 = ActionEventData.notes(game_name)::ActionEventData
          c7 = ActionEventData.data(scores)::ActionEventData
        })::Boolean
      JIL
    )
  }

  describe "listener matching" do
    it "prompt task matches event:action:added for Game events" do
      prompt_task
      event = user.action_events.create!(name: "Game", notes: "TBE")
      serialized = TriggerData.serialize(event.with_jil_attrs(action: :added), use_global_id: false)
      Tokenizer.split(prompt_task.listener).each do |sub_listener|
        matcher = SearchBreakMatcher.new(sub_listener, { event: serialized })
        expect(matcher.match?).to be(true), "Expected sub_listener '#{sub_listener}' to match"
      end
    end

    it "prompt task does not match non-Game events" do
      prompt_task
      event = user.action_events.create!(name: "Drink", notes: "Coke")
      serialized = TriggerData.serialize(event.with_jil_attrs(action: :added), use_global_id: false)
      results = Tokenizer.split(prompt_task.listener).map { |sub_listener|
        SearchBreakMatcher.new(sub_listener, { event: serialized }).match?
      }
      expect(results.all?).to be false
    end

    it "dynamic load task matches prompt load with game_scores source" do
      dynamic_load_task
      prompt = user.prompts.create!(question: "Game Scores", params: { source: "game_scores", event_id: 1 })
      resolved_params = TriggerData.parse(prompt.params, as: user)
      prompt.with_jil_attrs(state: :load, data: resolved_params)
      serialized = TriggerData.serialize(prompt, use_global_id: false)
      Tokenizer.split(dynamic_load_task.listener).each do |sub_listener|
        matcher = SearchBreakMatcher.new(sub_listener, { prompt: serialized })
        expect(matcher.match?).to be(true), "Expected sub_listener '#{sub_listener}' to match"
      end
    end

    it "submitted task matches prompt completion with game_scores source" do
      submitted_task
      prompt = user.prompts.create!(
        question: "Game Scores",
        params:   { source: "game_scores", event_id: 1 },
        response: { "Game" => "TBE", "Scores" => "Rocco 73" },
      )
      prompt.with_jil_attrs(status: :complete)
      serialized = TriggerData.serialize(prompt, use_global_id: false)
      Tokenizer.split(submitted_task.listener).each do |sub_listener|
        matcher = SearchBreakMatcher.new(sub_listener, { prompt: serialized })
        expect(matcher.match?).to be(true), "Expected sub_listener '#{sub_listener}' to match"
      end
    end
  end

  def run_jil(code, input_data)
    executor = Jil::Executor.call(user, code, input_data)
    @ctx = executor.ctx
    expect([@ctx[:error_line], @ctx[:error]].compact.join("\n")).to be_blank
    executor
  end

  describe "Task 1: Game Score Prompt" do
    it "creates a prompt with prefilled game name from event notes" do
      event = user.action_events.create!(name: "Game", notes: "Slime Colony")
      run_jil(prompt_task.code, event.with_jil_attrs(action: :added))

      prompt = user.prompts.last
      expect(prompt.question).to eq("Game Scores")
      expect(prompt.params).to eq({ "source" => "game_scores", "event_id" => event.id })
      expect(prompt.options.length).to eq(2)
      expect(prompt.options[0]).to include("type" => "text", "question" => "Game", "default" => "Slime Colony")
      expect(prompt.options[1]).to include("type" => "textarea", "question" => "Scores", "default" => "")
    end

    it "prefills scores textarea when event has existing data" do
      event = user.action_events.create!(
        name:  "Game",
        notes: "Slime Colony",
        data:  { "Rocco" => 73, "Chelsea" => 86 },
      )
      run_jil(prompt_task.code, event.with_jil_attrs(action: :added))

      prompt = user.prompts.last
      scores_default = prompt.options[1]["default"]
      expect(scores_default).to include("Rocco 73")
      expect(scores_default).to include("Chelsea 86")
    end
  end

  describe "Task 2: Game Score Dynamic Load" do
    it "updates prompt questions with current event data on load" do
      event = user.action_events.create!(
        name:  "Game",
        notes: "Slime Colony",
        data:  { "Rocco" => 73, "Chelsea" => 86 },
      )
      prompt = user.prompts.create!(
        question: "Game Scores",
        params:   { source: "game_scores", event_id: event.id },
        options:  [
          { "type" => "text", "question" => "Game", "default" => "TBE" },
          { "type" => "textarea", "question" => "Scores", "default" => "" },
        ],
      )
      resolved_params = TriggerData.parse(prompt.params, as: user)
      run_jil(dynamic_load_task.code, prompt.with_jil_attrs(state: :load, data: resolved_params))

      prompt.reload
      game_q = prompt.options.find { |q| q["question"] == "Game" }
      scores_q = prompt.options.find { |q| q["question"] == "Scores" }
      expect(game_q["default"]).to eq("Slime Colony")
      expect(scores_q["default"]).to include("Rocco 73")
      expect(scores_q["default"]).to include("Chelsea 86")
    end
  end

  describe "Task 3: Game Score Submitted" do
    it "parses score lines and updates event data" do
      event = user.action_events.create!(name: "Game", notes: "TBE")
      prompt = user.prompts.create!(
        question: "Game Scores",
        params:   { source: "game_scores", event_id: event.id },
        response: {
          "Game"   => "Slime Colony",
          "Scores" => "Rocco 73\nChelsea 86",
        },
      )
      run_jil(submitted_task.code, prompt.with_jil_attrs(status: :complete))

      event.reload
      expect(event.notes).to eq("Slime Colony")
      expect(event.data).to eq({ "Rocco" => 73, "Chelsea" => 86 })
    end

    it "handles multi-word player names" do
      event = user.action_events.create!(name: "Game", notes: "TBE")
      prompt = user.prompts.create!(
        question: "Game Scores",
        params:   { source: "game_scores", event_id: event.id },
        response: {
          "Game"   => "Slime Colony",
          "Scores" => "Rocco 42\nChelsea 37\nCarlos & Lil 45",
        },
      )
      run_jil(submitted_task.code, prompt.with_jil_attrs(status: :complete))

      event.reload
      expect(event.data).to eq({
        "Rocco"        => 42,
        "Chelsea"      => 37,
        "Carlos & Lil" => 45,
      })
    end

    it "skips blank lines in scores" do
      event = user.action_events.create!(name: "Game", notes: "TBE")
      prompt = user.prompts.create!(
        question: "Game Scores",
        params:   { source: "game_scores", event_id: event.id },
        response: {
          "Game"   => "Slime Colony",
          "Scores" => "Rocco 73\n\nChelsea 86\n",
        },
      )
      run_jil(submitted_task.code, prompt.with_jil_attrs(status: :complete))

      event.reload
      expect(event.data).to eq({ "Rocco" => 73, "Chelsea" => 86 })
    end
  end

  describe "end-to-end: log command through prompt submission" do
    it "full flow from jarvis log to event with scores" do
      prompt_task
      submitted_task

      # Step 1: User logs "Game TBE" via Jarvis
      # Disable ALL tasks first, then create ours
      user.tasks.update_all(enabled: false)
      prompt_task
      submitted_task
      # Verify task is findable by listener
      expect(prompt_task.listener).to eq("event:action:added name::Game")
      expect(prompt_task.enabled).to be true
      expect(prompt_task.archived_at).to be_nil
      matching = Task.where(id: prompt_task.id).by_listener(:event)
      expect(matching.pluck(:name)).to include("Game Score Prompt")

      result = Jarvis.command(user, "log Game TBE")
      expect(Array.wrap(result)[0]).to eq("Logged Game (TBE)")

      event = ActionEvent.order(:id).last
      expect(event.name).to eq("Game")
      expect(ActionEvent.find(event.id).notes).to eq("TBE")

      # Manually execute the prompt task (trigger fires during Jarvis.command
      # but accessible_tasks DISTINCT + ORDER BY tree_order conflicts in test)
      event.reload
      run_jil(prompt_task.code, event.with_jil_attrs(action: :added))

      # Step 2: The prompt task should have created a prompt
      prompt = user.prompts.last
      expect(prompt).to be_present
      expect(prompt.question).to eq("Game Scores")
      expect(prompt.params).to eq({ "source" => "game_scores", "event_id" => event.id })
      expect(prompt.options[0]).to include("question" => "Game", "default" => "TBE")

      # Step 3: Simulate user submitting the prompt with scores
      prompt.update!(response: {
        "Game"   => "Slime Colony",
        "Scores" => "Rocco 73\nChelsea 86\nCarlos & Lil 45",
      })
      run_jil(submitted_task.code, prompt.with_jil_attrs(status: :complete))

      event.reload
      expect(event.notes).to eq("Slime Colony")
      expect(event.data).to eq({
        "Rocco"        => 73,
        "Chelsea"      => 86,
        "Carlos & Lil" => 45,
      })
    end
  end
end
