require "rails_helper"

# End-to-end render of the REAL calendar page (controller -> @agendas ->
# add modal -> _form_fields), reproducing Chelsea's exact setup: she OWNS a
# personal agenda that she has shared OUT to another user. The "Notify others"
# checkbox is gated on the picker <li>'s data-shared, so that <li> must carry
# data-shared="true" for her OWN shared-out agenda.
RSpec.describe AgendasController, type: :controller do
  render_views

  let(:chelsea) { FactoryBot.create(:user, username: "chelsea_ctrl") }
  let(:rocco)   { FactoryBot.create(:user, username: "rocco_ctrl") }

  let!(:personal) do
    agenda = Agenda.create!(user: chelsea, name: "Alchemibluum")
    AgendaShare.create!(agenda: agenda, user: rocco, permission: :viewer)
    agenda
  end
  let!(:joint) do
    agenda = Agenda.create!(user: rocco, name: "Ours")
    AgendaShare.create!(agenda: agenda, user: chelsea, permission: :editor)
    agenda
  end

  before { sign_in chelsea }

  it "flags Chelsea's own shared-out personal agenda as shared in the picker" do
    get :day

    doc = Nokogiri::HTML(response.body)
    personal_li = doc.at_css("li[data-id='#{personal.id}']")
    joint_li    = doc.at_css("li[data-id='#{joint.id}']")

    expect(personal_li).to be_present, "personal agenda not in the picker at all"
    expect(joint_li).to be_present

    expect(joint_li["data-shared"]).to eq("true")       # already worked
    expect(personal_li["data-shared"]).to eq("true")    # the reported bug
  end
end
