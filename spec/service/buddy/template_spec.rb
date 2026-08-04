require "rails_helper"

RSpec.describe Buddy::Template do
  let(:user)  { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

  def render(body, vars = {})
    described_class.render(body, vars, user: user, conversation: convo)
  end

  describe ".templated?" do
    it "is true only when there's something to render" do
      expect(described_class).to be_templated("{{ name }}")
      expect(described_class).to be_templated("{% if x %}a{% endif %}")
      expect(described_class).not_to be_templated("just a sentence")
      expect(described_class).not_to be_templated("")
    end
  end

  describe ".render" do
    it "leaves a plain sentence completely alone" do
      expect(render("Bins go out tonight.")).to eq("Bins go out tonight.")
    end

    it "substitutes what it was given" do
      expect(render("{{ name }} landed", "name" => "Milk")).to eq("Milk landed")
    end

    # The reason for reaching for Liquid rather than writing a substitution:
    # the moment there's a placeholder, the next thing wanted is a filter.
    it "runs filters" do
      expect(render('{{ name | remove: ">" | strip }}', "name" => ">main Permission")).to eq("main Permission")
      expect(render("{{ name | upcase }}", "name" => "milk")).to eq("MILK")
      expect(render("{{ name | default: 'something' }}")).to eq("something")
    end

    it "branches" do
      body = "{% if outcome == 'failed' %}broke{% else %}fine{% endif %}"

      expect(render(body, "outcome" => "failed")).to eq("broke")
      expect(render(body, "outcome" => "success")).to eq("fine")
    end

    it "reads a nested key by path" do
      expect(render("{{ item.name }}", "item" => { "name" => "Milk" })).to eq("Milk")
    end

    it "leaves a blank for a variable nothing supplied" do
      expect(render("{{ name }} went on {{ list }}", "name" => "Milk")).to eq("Milk went on")
    end
  end

  # Every template gets these whatever it's hanging off, so a reminder with no
  # trigger behind it still has something to say beyond its own words.
  describe "the base context" do
    it "knows the clock, the day, and who everyone is" do
      expect(render("{{ greeting }}, {{ user }}")).to eq("#{described_class.greeting_for(Time.current.in_time_zone(user.timezone).hour)}, #{user.first_name}")
      expect(render("{{ buddy }}")).to eq(convo.buddy_name)
      expect(render("{{ weekday }}")).to eq(Time.current.in_time_zone(user.timezone).strftime("%A"))
    end

    it "is overridable by what the caller passes" do
      expect(render("{{ user }}", "user" => "someone else")).to eq("someone else")
    end

    it "still works with no user at all" do
      expect(described_class.render("{{ weekday }}", {})).to be_present
    end
  end

  # A template is data typed into a form. Nothing it can contain is allowed to
  # stop a notification going out - the person is waiting on a doorbell or a
  # deploy, and silence is the one outcome that can't happen.
  describe "when the template is broken" do
    it "falls back to the raw body rather than raising" do
      expect(render("{% nonsense %}the doorbell went")).to include("the doorbell went")
    end

    it "falls back rather than returning an empty line" do
      expect(render("{{ missing }}")).to eq("{{ missing }}")
    end

    it "cannot reach a Ruby object it was handed" do
      expect(render("{{ user.password_digest }}", "user" => user)).to eq("{{ user.password_digest }}")
    end
  end

  describe ".error_in" do
    it "is nil for a template that parses" do
      expect(described_class.error_in("{{ name }}")).to be_nil
      expect(described_class.error_in("plain words")).to be_nil
    end

    it "says what's wrong with one that doesn't" do
      expect(described_class.error_in("{% if x %}no end")).to be_present
      expect(described_class.error_in("{% nope %}")).to be_present
    end
  end

  describe ".variables_for" do
    it "lists what a template could use, showing what each renders to now" do
      vars = described_class.variables_for(user, { "name" => "Milk" }, conversation: convo)

      expect(vars).to include("name" => "Milk", "buddy" => convo.buddy_name)
      expect(vars["weekday"]).to be_present
    end
  end
end
