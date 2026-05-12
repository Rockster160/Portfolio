RSpec.describe "Game Score Tasks" do
  include ActiveJob::TestHelper

  let(:user) { User.me }

  let(:prompt_code) {
    <<~'JIL'.strip
      *event = Global.input_data()::ActionEvent
      *event_id = event.id()::Numeric
      *game_name = event.notes()::String
      *existing_data = event.data()::Hash
      *event_time = event.timestamp()::Date
      *dur_default = existing_data.get("duration")::String
      *players_hash = existing_data.get("players")::Hash
      *has_scores = players_hash.presence()::Boolean
      *score_default = Global.if({
        sif = Global.ref(has_scores)::Boolean
      }, {
        score_arr = players_hash.map({
          key = Keyword.Key()::String
          val = Keyword.Value()::Any
          sd_ln = String.new("#{key} #{val}")::String
        })::Array
        sd_join = score_arr.join("\\n")::String
      }, {
        sd_empty = String.new("")::String
      })::String
      prompt_data = Hash.new({
        pd1 = Keyval.new("source", "game_scores")::Keyval
        pd2 = Keyval.new("event_id", event_id)::Keyval
      })::Hash
      *result = Prompt.create("Enter Game Scores", prompt_data, {
        pq1 = PromptQuestion.text("Game", game_name)::PromptQuestion
        pq2 = PromptQuestion.datetime("Started", event_time)::PromptQuestion
        pq3 = PromptQuestion.text("Duration", dur_default)::PromptQuestion
        pq4 = PromptQuestion.textarea("Scores", score_default)::PromptQuestion
      }, true)::Prompt
    JIL
  }

  let(:dynamic_load_code) {
    <<~'JIL'.strip
      *prompt = Global.input_data()::Prompt
      *pdata = prompt.data()::Hash
      event_id = pdata.get("event_id")::Numeric
      *event = ActionEvent.find(event_id)::ActionEvent
      *game_name = event.notes()::String
      *existing_data = event.data()::Hash
      *event_time = event.timestamp()::Date
      *dur_default = existing_data.get("duration")::String
      *players_hash = existing_data.get("players")::Hash
      *has_scores = players_hash.presence()::Boolean
      *score_default = Global.if({
        bif = Global.ref(has_scores)::Boolean
      }, {
        score_arr = players_hash.map({
          key = Keyword.Key()::String
          val = Keyword.Value()::Any
          bd_ln = String.new("#{key} #{val}")::String
        })::Array
        bd_join = score_arr.join("\\n")::String
      }, {
        bd_empty = String.new("")::String
      })::String
      *orig_questions = prompt.questions()::Array
      filtered_questions = orig_questions.reject({
        q = Keyword.Object()::Hash
        qname = q.get("question")::String
        qmatch = qname.match("/^(Game|Started|Duration|Scores)$/")::Boolean
      })::Array
      gameQ = PromptQuestion.text("Game", game_name)::PromptQuestion
      startedQ = PromptQuestion.datetime("Started", event_time)::PromptQuestion
      durationQ = PromptQuestion.text("Duration", dur_default)::PromptQuestion
      scoresQ = PromptQuestion.textarea("Scores", score_default)::PromptQuestion
      b5 = filtered_questions.push!(gameQ)::Array
      b5b = filtered_questions.push!(startedQ)::Array
      b5c = filtered_questions.push!(durationQ)::Array
      *b6 = filtered_questions.push!(scoresQ)::Array
      *b7 = prompt.update("", "", {
        bref = Global.ref(filtered_questions)::Array
      })::Boolean
    JIL
  }

  let(:submitted_code) {
    <<~'JIL'.strip
      *input = Global.input_data()::Hash
      prms = input.get("params")::Hash
      event_id = prms.get("event_id")::Numeric
      response = input.get("response")::Hash
      game_name = response.get("Game")::String
      started_at = response.get("Started")::Date
      duration_str = response.get("Duration")::String
      raw_scores = response.get("Scores")::String
      *lines = raw_scores.split("\\n")::Array
      players = Hash.new({})::Hash
      c0 = lines.each({
        raw_line = Keyword.Value()::String
        line = raw_line.format("squish")::String
        c1 = Global.if({
          c2 = line.presence()::Boolean
        }, {
          *parts = line.match("/^(?<player>.+)\\s+(?<score>[\\d,]+)$/")::Hash
          *player = parts.get("player")::String
          *score_str = parts.get("score")::String
          score = String.new(score_str)::Numeric
          c3 = players.set!(player, score)::Hash
        }, {
          c4 = Global.comment("skip blank line")::None
        })::Any
      })::Array
      final_data = Hash.new({
        fd1 = Keyval.new("players", players)::Keyval
      })::Hash
      fd2 = Global.if({
        fd3 = duration_str.presence()::Boolean
      }, {
        fd4 = final_data.set!("duration", duration_str)::Hash
      }, {
        fd5 = Global.comment("no duration")::None
      })::Any
      event = ActionEvent.find(event_id)::ActionEvent
      *c5 = event.update!({
        c6 = ActionEventData.notes(game_name)::ActionEventData
        c7 = ActionEventData.timestamp(started_at)::ActionEventData
        c8 = ActionEventData.data({
          fdref = Global.ref(final_data)::Hash
        })::ActionEventData
      })::Boolean
    JIL
  }

  let(:prompt_task) {
    user.tasks.create!(
      name:     "Game Score Prompt",
      listener: "event:action:added name::Game",
      code:     prompt_code,
    )
  }

  let(:dynamic_load_task) {
    user.tasks.create!(
      name:     "Game Score Dynamic Load",
      listener: "prompt:state:load params:source:game_scores",
      code:     dynamic_load_code,
    )
  }

  let(:submitted_task) {
    user.tasks.create!(
      name:     "Game Score Submitted",
      listener: "prompt:params:source:game_scores",
      code:     submitted_code,
    )
  }

  def run_jil(code, input_data)
    executor = Jil::Executor.call(user, code, input_data)
    @ctx = executor.ctx
    expect([@ctx[:error_line], @ctx[:error]].compact.join("\n")).to be_blank
    executor
  end

  describe "Task 1: Game Score Prompt" do
    it "creates a prompt with Game/Started/Duration/Scores fields prefilled from event" do
      event = user.action_events.create!(name: "Game", notes: "Slime Colony")
      run_jil(prompt_task.code, event.with_jil_attrs(action: :added))

      prompt = user.prompts.last
      expect(prompt.question).to eq("Enter Game Scores")
      expect(prompt.params).to eq({ "source" => "game_scores", "event_id" => event.id })
      qs = prompt.options.map { |o| o["question"] }
      expect(qs).to eq(["Game", "Started", "Duration", "Scores"])
      expect(prompt.options[0]["default"]).to eq("Slime Colony")
      expect(prompt.options[3]["default"]).to eq("")
    end

    it "prefills Scores from nested players hash" do
      event = user.action_events.create!(
        name:  "Game",
        notes: "Slime Colony",
        data:  { "players" => { "Rocco" => 73, "Chelsea" => 86 }, "duration" => "120" },
      )
      run_jil(prompt_task.code, event.with_jil_attrs(action: :added))

      prompt = user.prompts.last
      duration_q = prompt.options.find { |o| o["question"] == "Duration" }
      scores_q = prompt.options.find { |o| o["question"] == "Scores" }
      expect(duration_q["default"]).to eq("120")
      expect(scores_q["default"]).to include("Rocco 73")
      expect(scores_q["default"]).to include("Chelsea 86")
    end
  end

  describe "Task 3: Game Score Submitted" do
    it "parses scores into nested players hash with duration alongside" do
      event = user.action_events.create!(name: "Game", notes: "TBE")
      prompt = user.prompts.create!(
        question: "Enter Game Scores",
        params:   { source: "game_scores", event_id: event.id },
        response: {
          "Game"     => "Slime Colony",
          "Started"  => "2026-05-09T00:26",
          "Duration" => "165",
          "Scores"   => "Rocco 73\nChelsea 86",
        },
      )
      run_jil(submitted_task.code, prompt.with_jil_attrs(status: :complete))

      event.reload
      expect(event.notes).to eq("Slime Colony")
      expect(event.data).to eq({
        "players"  => { "Rocco" => 73, "Chelsea" => 86 },
        "duration" => "165",
      })
    end

    it "parses scores when Duration is blank (no duration key)" do
      event = user.action_events.create!(name: "Game", notes: "TBE")
      prompt = user.prompts.create!(
        question: "Enter Game Scores",
        params:   { source: "game_scores", event_id: event.id },
        response: {
          "Game"     => "Wyrmspan",
          "Started"  => "2026-05-09T00:26",
          "Duration" => "",
          "Scores"   => "Rocco 95\nChelsea 65",
        },
      )
      run_jil(submitted_task.code, prompt.with_jil_attrs(status: :complete))

      event.reload
      expect(event.data).to eq({
        "players" => { "Rocco" => 95, "Chelsea" => 65 },
      })
    end

    it "regex matches with multi-word player names and CRLF line endings" do
      event = user.action_events.create!(name: "Game", notes: "TBE")
      prompt = user.prompts.create!(
        question: "Enter Game Scores",
        params:   { source: "game_scores", event_id: event.id },
        response: {
          "Game"     => "EmberLeaf",
          "Started"  => "2026-05-09T00:26",
          "Duration" => "165",
          "Scores"   => "Chelsea 96\r\nRocco 83\r\nCarlos & Lil 45\r\nSaya 62",
        },
      )
      run_jil(submitted_task.code, prompt.with_jil_attrs(status: :complete))

      event.reload
      expect(event.data["players"]).to eq({
        "Chelsea"      => 96,
        "Rocco"        => 83,
        "Carlos & Lil" => 45,
        "Saya"         => 62,
      })
    end

    it "skips blank lines" do
      event = user.action_events.create!(name: "Game", notes: "TBE")
      prompt = user.prompts.create!(
        question: "Enter Game Scores",
        params:   { source: "game_scores", event_id: event.id },
        response: {
          "Game"     => "Game",
          "Started"  => "2026-05-09T00:26",
          "Duration" => "30",
          "Scores"   => "Rocco 73\n\nChelsea 86\n",
        },
      )
      run_jil(submitted_task.code, prompt.with_jil_attrs(status: :complete))

      event.reload
      expect(event.data["players"]).to eq({ "Rocco" => 73, "Chelsea" => 86 })
    end
  end

  describe "Task 2: Game Score Dynamic Load" do
    it "rebuilds questions from event with nested players hash" do
      event = user.action_events.create!(
        name:  "Game",
        notes: "Slime Colony",
        data:  { "players" => { "Rocco" => 73, "Chelsea" => 86 }, "duration" => "120" },
      )
      prompt = user.prompts.create!(
        question: "Enter Game Scores",
        params:   { source: "game_scores", event_id: event.id },
        options:  [
          { "type" => "text", "question" => "Game", "default" => "TBE" },
          { "type" => "datetime", "question" => "Started", "default" => "" },
          { "type" => "text", "question" => "Duration", "default" => "" },
          { "type" => "textarea", "question" => "Scores", "default" => "" },
        ],
      )
      resolved_params = TriggerData.parse(prompt.params, as: user)
      run_jil(dynamic_load_task.code, prompt.with_jil_attrs(state: :load, data: resolved_params))

      prompt.reload
      qs = prompt.options.index_by { |o| o["question"] }
      expect(qs["Game"]["default"]).to eq("Slime Colony")
      expect(qs["Duration"]["default"]).to eq("120")
      expect(qs["Scores"]["default"]).to include("Rocco 73")
      expect(qs["Scores"]["default"]).to include("Chelsea 86")
    end
  end
end
