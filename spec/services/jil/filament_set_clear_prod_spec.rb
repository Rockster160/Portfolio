RSpec.describe "Filament set-clear scripts match prod code" do
  let(:form_prod_code) { <<~'JIL'.strip }
    input = Global.input_data()::Hash
    input_params = input.get("params")::Hash
    fil_name = input_params.get("name")::String
    input_action = input_params.get("do")::String
    is_set_action = input_action.match("/^set$/")::Boolean
    y1 = Global.if({
      y2 = Global.ref(is_set_action)::Boolean
    }, {
      y3 = Global.set_cache("printer", "active_filament", fil_name)::Any
      set_fils = Global.get_cache("printer", "filaments")::Hash
      set_data = set_fils.get(fil_name)::Hash
      set_color = set_data.get("color")::String
      set_cur = Global.get_cache("printer", "current")::Hash
      y4 = set_cur.set!("filament_name", fil_name)::Hash
      y5 = set_cur.set!("filament_color", set_color)::Hash
      y6 = Global.set_cache("printer", "current", set_cur)::Any
      y7 = Monitor.refresh("printer", "")::Hash
      set_redir = Hash.new({
        y8 = Keyval.new("redirect", "/jil/p/309")::Keyval
        y9 = Keyval.new("notice", "Switched to #{fil_name}")::Keyval
      })::Hash
      ya = Global.return(set_redir)::Hash
    }, {})::Any
    response = input.get("response")::Hash
    has_response = response.presence()::Boolean
    z1 = Global.if({
      z2 = Global.ref(has_response)::Boolean
    }, {})::Any
  JIL

  let(:complete_prod_code) { <<~'JIL'.strip }
    *prompt = Global.input_data()::Prompt
    *pdata = prompt.data()::Hash
    action = pdata.get("action")::String
    response = prompt.response()::Hash
    is_set = action.match("/^set$/")::Boolean
    z4 = Global.if({
      g1 = Global.ref(is_set)::Boolean
    }, {
      set_fil = response.get("Filament")::String
      g2 = Global.set_cache("printer", "active_filament", set_fil)::Any
      all_fils = Global.get_cache("printer", "filaments")::Hash
      fil_data = all_fils.get(set_fil)::Hash
      fil_color = fil_data.get("color")::String
      set_cur = Global.get_cache("printer", "current")::Hash
      g5 = set_cur.set!("filament_name", set_fil)::Hash
      g6 = set_cur.set!("filament_color", fil_color)::Hash
      g7 = Global.set_cache("printer", "current", set_cur)::Any
      set_status = set_cur.get("status")::String
      printing = set_status.match("printing")::Boolean
      g3 = Global.if({
        h1 = Global.ref(printing)::Boolean
      }, {
        set_evt_id = set_cur.get("event_id")::Numeric
        h2 = Custom.ChangeEventFilament(set_evt_id, set_fil)::Hash
      }, {})::Any
      g4 = Monitor.refresh("printer", "")::Hash
    }, {})::Any
  JIL

  describe "Form do=set regex substitution" do
    it "matches the prod code and produces valid Jil" do
      script = File.read(Rails.root.join("lib/scripts/fix_filament_set_clear_current.rb"))

      # Extract the replacement Jil from the script
      replacement = script[/form_code = form_code\.sub\(\n.*?\n(.*?)\n\)/m, 1]
        &.strip&.gsub(/^  /, "")

      # Apply the same regex to prod code
      regex = /y3 = Global\.set_cache.*?ya = Global\.return\(set_redir\)::Hash/m
      expect(form_prod_code).to match(regex), "Regex does not match prod Form code"

      result_code = form_prod_code.sub(regex, replacement)
      expect(result_code).not_to eq(form_prod_code), "Substitution had no effect"

      Jil::Validator.validate!(result_code)
    end
  end

  describe "Prompt Complete set regex substitution" do
    it "matches the prod code and produces valid Jil" do
      script = File.read(Rails.root.join("lib/scripts/fix_filament_set_clear_current.rb"))

      regex = /set_fil = response\.get\("Filament"\).*?g4 = Monitor\.refresh\("printer", ""\)::Hash/m
      expect(complete_prod_code).to match(regex), "Regex does not match prod Complete code"

      replacement = script[/complete_code = complete_code\.sub\(\n.*?\n(.*?)\n\)/m, 1]
        &.strip&.gsub(/^  /, "")

      result_code = complete_prod_code.sub(regex, replacement)
      expect(result_code).not_to eq(complete_prod_code), "Substitution had no effect"

      Jil::Validator.validate!(result_code)
    end
  end

  describe "Monitor Load full replacement" do
    it "validates the complete new code" do
      script = File.read(Rails.root.join("lib/scripts/fix_monitor_load_idle.rb"))
      jil_code = script[/task\.update!\(code: <<~'JIL'\.strip\)\n(.*?)\nJIL/m, 1]

      expect(jil_code).to be_present, "Could not extract Jil code from script"
      Jil::Validator.validate!(jil_code)
    end
  end
end
