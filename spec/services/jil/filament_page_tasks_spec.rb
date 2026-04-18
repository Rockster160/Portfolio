RSpec.describe "Filament Page Tasks" do
  let(:user) { User.me }

  let(:page_code) { <<~'JIL'.strip }
    filaments = Global.get_cache("printer", "filaments")::Hash
    active = Global.get_cache("printer", "active_filament")::String
    rows = filaments.map({
      name = Keyword.Key()::String
      data = Keyword.Value()::Hash
      color = data.get("color")::String
      rem_g = data.get("remaining_g")::Numeric
      rem_g_r = rem_g.round(0)::Numeric
      row = String.new("| [[#{color}]](#{name}) | #{rem_g_r}g | [btn /jil/f/FORM_ID?name=#{name}](Edit) |")::String
    })::Array
    table_body = rows.join("\n")::String
    has_active = active.presence()::Boolean
    active_fils = Global.get_cache("printer", "filaments")::Hash
    active_data = active_fils.get(active)::Hash
    active_color = active_data.get("color")::String
    header = Global.if({
      h1 = Global.ref(has_active)::Boolean
    }, {
      h2 = String.new("Current: [[#{active_color}]](#{active})\n\n")::String
    }, {
      h3 = String.new("")::String
    })::String
    content = String.new("#{header}| Filament | Remaining | [btn /jil/f/FORM_ID?name=](Add New) |\n| --- | --- | --- |\n#{table_body}")::String
    result = Hash.new({
      r1 = Keyval.new("title", "Filaments")::Keyval
      r2 = Keyval.new("content", content)::Keyval
    })::Hash
    ret = Global.return(result)::Hash
  JIL

  let(:form_code) { <<~'JIL'.strip }
    input = Global.input_data()::Hash
    input_params = input.get("params")::Hash
    fil_name = input_params.get("name")::String
    response = input.get("response")::Hash
    has_response = response.presence()::Boolean
    z1 = Global.if({
      z2 = Global.ref(has_response)::Boolean
    }, {
      new_name = response.get("Name")::String
      new_color = response.get("Color")::String
      new_notes = response.get("Notes")::String
      new_weight = response.get("Weight (g)")::Numeric
      mm_per_g = Global.get_cache("printer", "mm_per_gram")::Numeric
      new_mm = Numeric.op(new_weight, "*", mm_per_g)::Numeric
      filaments = Global.get_cache("printer", "filaments")::Hash
      name_changed = Boolean.compare(fil_name, "!=", new_name)::Boolean
      has_old = fil_name.presence()::Boolean
      z3 = Global.if({
        z4 = Boolean.and(has_old, name_changed)::Boolean
      }, {
        z7 = filaments.del!(fil_name)::Hash
      }, {})::Any
      save_fil = Hash.new({
        s1 = Keyval.new("color", new_color)::Keyval
        s2 = Keyval.new("notes", new_notes)::Keyval
        s3 = Keyval.new("remaining_mm", new_mm)::Keyval
        s4 = Keyval.new("remaining_g", new_weight)::Keyval
      })::Hash
      s5 = filaments.set!(new_name, save_fil)::Hash
      s6 = Global.set_cache("printer", "filaments", filaments)::Any
      act = Global.get_cache("printer", "active_filament")::String
      was_active = Boolean.compare(act, "==", fil_name)::Boolean
      s7 = Global.if({
        s8 = Global.ref(was_active)::Boolean
      }, {
        s9 = Global.set_cache("printer", "active_filament", new_name)::Any
        cur = Global.get_cache("printer", "current")::Hash
        sa = cur.set!("filament_name", new_name)::Hash
        sb = cur.set!("filament_color", new_color)::Hash
        sc = Global.set_cache("printer", "current", cur)::Any
      }, {})::Any
      existing_sec = Section.find("Prints", fil_name)::Section
      has_sec = existing_sec.id()::Numeric
      sec_exists = has_sec.positive?()::Boolean
      sd = Global.if({
        se = Global.ref(sec_exists)::Boolean
      }, {
        sf = existing_sec.update!(new_name, new_color)::Boolean
      }, {
        sg = Section.create("Prints", new_name, new_color)::Section
      })::Any
      redir = Hash.new({
        r1 = Keyval.new("redirect", "/jil/p/PAGE_ID")::Keyval
        r2 = Keyval.new("notice", "Filament saved!")::Keyval
      })::Hash
      z8 = Global.return(redir)::Hash
    }, {})::Any
    has_name = fil_name.presence()::Boolean
    z9 = Global.if({
      za = Global.ref(has_name)::Boolean
    }, {
      all_fils = Global.get_cache("printer", "filaments")::Hash
      fil = all_fils.get(fil_name)::Hash
      cur_color = fil.get("color")::String
      cur_notes = fil.get("notes")::String
      cur_g = fil.get("remaining_g")::Numeric
      form_title = String.new("Edit #{fil_name}")::String
      form_result = Hash.new({
        f1 = Keyval.new("title", form_title)::Keyval
        f2 = Keyval.new("options", "OPTS")::Keyval
      })::Hash
      nameQ = PromptQuestion.text("Name", fil_name)::PromptQuestion
      colorQ = PromptQuestion.color("Color", cur_color)::PromptQuestion
      notesQ = PromptQuestion.textarea("Notes", cur_notes)::PromptQuestion
      weightQ = PromptQuestion.number("Weight (g)", cur_g, 0, 10000, 1)::PromptQuestion
      opts = Array.new({
        o1 = Global.ref(nameQ)::PromptQuestion
        o2 = Global.ref(colorQ)::PromptQuestion
        o3 = Global.ref(notesQ)::PromptQuestion
        o4 = Global.ref(weightQ)::PromptQuestion
      })::Array
      zb = form_result.set!("options", opts)::Hash
      zc = Global.return(form_result)::Hash
    }, {
      new_result = Hash.new({
        n1 = Keyval.new("title", "Add Filament")::Keyval
        n2 = Keyval.new("options", "OPTS")::Keyval
      })::Hash
      newNameQ = PromptQuestion.text("Name", "")::PromptQuestion
      newColorQ = PromptQuestion.color("Color", "#000000")::PromptQuestion
      newNotesQ = PromptQuestion.textarea("Notes", "")::PromptQuestion
      newWeightQ = PromptQuestion.number("Weight (g)", 1000, 0, 10000, 1)::PromptQuestion
      new_opts = Array.new({
        no1 = Global.ref(newNameQ)::PromptQuestion
        no2 = Global.ref(newColorQ)::PromptQuestion
        no3 = Global.ref(newNotesQ)::PromptQuestion
        no4 = Global.ref(newWeightQ)::PromptQuestion
      })::Array
      zd = new_result.set!("options", new_opts)::Hash
      ze = Global.return(new_result)::Hash
    })::Any
  JIL

  describe "validation" do
    it "page code passes Jil::Validator" do
      Jil::Validator.validate!(page_code)
    end

    it "form code passes Jil::Validator" do
      Jil::Validator.validate!(form_code)
    end
  end

  describe "page execution" do
    before do
      user.action_events.destroy_all
      user.caches.by(:printer).update!(data: {
        filaments: {
          "Red PLA": { color: "#FF0000", remaining_mm: 300_000, remaining_g: 895.5 },
          "Blue PETG": { color: "#0000FF", remaining_mm: 200_000, remaining_g: 597.0 },
        },
        active_filament: "Red PLA",
        mm_per_gram: 335,
      })
    end

    it "returns title and markdown content with filament rows" do
      executor = Jil::Executor.call(user, page_code, { page: true })
      result = executor.ctx[:return_val]

      expect(result).to be_a(Hash)
      expect(result["title"]).to eq("Filaments")
      expect(result["content"]).to include("Red PLA")
      expect(result["content"]).to include("Blue PETG")
      expect(result["content"]).to include("896g") # 895.5 rounded
      expect(result["content"]).to include("Current:") # active filament header
    end
  end

  describe "form execution" do
    before do
      user.action_events.destroy_all
      user.caches.by(:printer).update!(data: {
        filaments: {
          "Red PLA": { color: "#FF0000", notes: "Hatchbox", remaining_mm: 300_000, remaining_g: 895.5 },
        },
        active_filament: "Red PLA",
        mm_per_gram: 335,
      })
      @prints_list = user.lists.find_or_create_by!(name: "Prints")
    end

    it "returns edit form with pre-filled fields when name given" do
      executor = Jil::Executor.call(user, form_code, { params: { name: "Red PLA" } })
      result = executor.ctx[:return_val]

      expect(result).to be_a(Hash)
      expect(result["title"]).to include("Red PLA")
      expect(result["options"]).to be_an(Array)
      expect(result["options"].length).to eq(4)
      expect(result["options"].first).to include("question" => "Name", "default" => "Red PLA")
    end

    it "returns add form when name is blank" do
      executor = Jil::Executor.call(user, form_code, { params: { name: "" } })
      result = executor.ctx[:return_val]

      expect(result["title"]).to eq("Add Filament")
      expect(result["options"].first).to include("question" => "Name", "default" => "")
    end

    it "updates active_filament and current cache when renaming active filament" do
      executor = Jil::Executor.call(user, form_code, {
        params: { name: "Red PLA" },
        response: { "Name" => "Crimson PLA", "Color" => "#CC0000", "Notes" => "Renamed", "Weight (g)" => "895" },
      })
      result = executor.ctx[:return_val]
      expect(result["redirect"]).to be_present

      cache = user.caches.by(:printer)
      cache.reload
      expect(cache.dig("filaments", "Red PLA")).to be_nil
      expect(cache.dig("filaments", "Crimson PLA", "color")).to eq("#CC0000")
      expect(cache.dig("active_filament")).to eq("Crimson PLA")
      expect(cache.dig("current", "filament_name")).to eq("Crimson PLA")
      expect(cache.dig("current", "filament_color")).to eq("#CC0000")
    end

    it "creates a section in Prints list for new filaments" do
      executor = Jil::Executor.call(user, form_code, {
        params: { name: "" },
        response: { "Name" => "Green ABS", "Color" => "#00FF00", "Notes" => "", "Weight (g)" => "1000" },
      })
      expect(executor.ctx[:return_val]["redirect"]).to be_present

      section = @prints_list.sections.find_by(name: "Green ABS")
      expect(section).to be_present
      expect(section.color).to eq("#00FF00")
    end

    it "updates section in Prints list when renaming filament" do
      @prints_list.sections.create!(name: "Red PLA", color: "#FF0000")

      executor = Jil::Executor.call(user, form_code, {
        params: { name: "Red PLA" },
        response: { "Name" => "Crimson", "Color" => "#CC0000", "Notes" => "", "Weight (g)" => "800" },
      })
      expect(executor.ctx[:return_val]["redirect"]).to be_present

      expect(@prints_list.sections.find_by(name: "Red PLA")).to be_nil
      section = @prints_list.sections.find_by(name: "Crimson")
      expect(section).to be_present
      expect(section.color).to eq("#CC0000")
    end

    it "saves filament and returns redirect on submit" do
      executor = Jil::Executor.call(user, form_code, {
        params: { name: "Red PLA" },
        response: { "Name" => "Red PLA+", "Color" => "#FF1111", "Notes" => "Updated", "Weight (g)" => "800" },
      })
      result = executor.ctx[:return_val]

      expect(result["redirect"]).to include("/jil/p/")

      cache = user.caches.by(:printer)
      cache.reload
      expect(cache.dig("filaments", "Red PLA+", "color")).to eq("#FF1111")
      expect(cache.dig("filaments", "Red PLA+", "remaining_g")).to eq(800)
      expect(cache.dig("filaments", "Red PLA")).to be_nil # old name removed
    end
  end
end
