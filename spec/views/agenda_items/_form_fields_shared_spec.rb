require "rails_helper"

RSpec.describe "agenda_items/_form_fields" do
  let(:owner) { FactoryBot.create(:user, username: "chelsea_test") }
  let(:other) { FactoryBot.create(:user, username: "rocco_test") }

  def data_shared_for(agenda, current_user:, agendas:)
    allow(view).to receive(:current_user).and_return(current_user)
    rendered = render(
      partial: "agenda_items/form_fields",
      locals: { agendas: agendas, mode: :add, default_date: "2026-07-30" },
    )
    li = Nokogiri::HTML.fragment(rendered).at_css("li[data-id='#{agenda.id}']")
    li && li["data-shared"]
  end

  it "flags an agenda the current user OWNS and has shared OUT as shared" do
    agenda = Agenda.create!(user: owner, name: "Alchemibluum")
    AgendaShare.create!(agenda: agenda, user: other, permission: :viewer)

    expect(data_shared_for(agenda, current_user: owner, agendas: [agenda])).to eq("true")
  end

  it "flags an agenda shared TO the current user as shared" do
    agenda = Agenda.create!(user: other, name: "Ours")
    AgendaShare.create!(agenda: agenda, user: owner, permission: :editor)

    expect(data_shared_for(agenda, current_user: owner, agendas: [agenda])).to eq("true")
  end

  it "does NOT flag a solo owned agenda" do
    agenda = Agenda.create!(user: owner, name: "Solo")

    expect(data_shared_for(agenda, current_user: owner, agendas: [agenda])).to eq("false")
  end
end
