require "rails_helper"

RSpec.describe Buddy::Tools do
  describe ".bash_template" do
    it "shell-escapes payload values before substituting" do
      cmd = described_class.bash_template("echo {{name}}", { name: '"; rm -rf ~' })
      # Every metachar gets a leading backslash — the shell will see one
      # literal argument, not a chained command or a tilde expansion.
      expect(cmd).to eq(%q{echo \"\;\ rm\ -rf\ \~})
      expect(cmd).to include('\;')  # metachars escaped, not stripped
    end

    it "handles multi-placeholder templates" do
      cmd = described_class.bash_template("cp {{src}} {{dst}}", { src: "a.txt", dst: "b b.txt" })
      expect(cmd).to eq("cp a.txt b\\ b.txt")
    end
  end

  describe ".validate_payload" do
    let(:tool) {
      {
        args: {
          name:  { type: :string,  required: true },
          count: { type: :integer, required: false, default: 1 },
        },
      }
    }

    it "returns errors when required args are missing" do
      _, errors = described_class.validate_payload(tool, {})
      expect(errors).to include(a_string_matching(/missing required arg :name/))
    end

    it "coerces integers" do
      normalized, errors = described_class.validate_payload(tool, { name: "hi", count: "3" })
      expect(errors).to be_empty
      expect(normalized).to eq(name: "hi", count: 3)
    end

    it "accepts count as a top-level convention even without declaration" do
      minimal = { args: { name: { type: :string, required: true } } }
      normalized, errors = described_class.validate_payload(minimal, { name: "Water", count: "5" })
      expect(errors).to be_empty
      expect(normalized[:count]).to eq(5)
    end
  end

  describe ".system_prompt_appendix" do
    it "renders every registered tool with its arg list" do
      # Load real tool files so we're testing the actual registry state.
      Dir[Rails.root.join("app/service/buddy/tools/*.rb")].sort.each { |f| load f }
      out = described_class.system_prompt_appendix
      expect(out).to include("complete_chore")
      expect(out).to include("add_agenda_item")
      expect(out).to include("[[propose:")
    end
  end
end
