require "rails_helper"

# Pictures pasted into a note's body. The upload answers with the markdown that
# shows the picture, and the timeline renders that markdown as a picture while
# leaving everything else about the body verbatim.
#
# The examples about what it REFUSES are the point of the rest: a body is text
# somebody typed, so an embed is only ever drawn when it points at a picture
# this app is holding for this user. Anything else stays the characters that
# were typed, which is what stops a note fetching an image from somewhere else.
RSpec.describe "Pictures in a note", type: :request do
  let(:user) { create(:user) }
  let(:job) { user.job_applications.create!(company: "Podium") }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  def picture(name: "IMG (1).PNG", type: "image/png")
    Rack::Test::UploadedFile.new(StringIO.new("fake png"), type, original_filename: name)
  end

  def note!(body)
    Sidekiq::Testing.fake! {
      job.notes.create!(tag: :interview, occurred_at: 1.hour.ago, body: body)
    }
  end

  it "stores the picture on the application and answers with the markdown that shows it" do
    post interview_note_images_path(job), params: { file: picture }

    attachment = job.reload.note_images.sole
    expect(response.parsed_body["markdown"])
      .to eq("![Photo](#{interview_note_image_path(attachment.id)})")
  end

  it "serves the picture behind the short path the markdown points at" do
    post interview_note_images_path(job), params: { file: picture }
    attachment = job.reload.note_images.sole

    get interview_note_image_path(attachment.id)

    expect(response).to redirect_to(rails_blob_path(attachment.blob, only_path: true))
  end

  it "never serves another user's picture" do
    other = create(:user).job_applications.create!(company: "Theirs")
    other.note_images.attach(
      io:           StringIO.new("png"),
      filename:     "theirs.png",
      content_type: "image/png",
    )
    attachment = other.note_images.sole

    get interview_note_image_path(attachment.id)

    expect(response).not_to redirect_to(rails_blob_path(attachment.blob, only_path: true))
  end

  it "refuses a file that isn't a picture" do
    file = Rack::Test::UploadedFile.new(
      StringIO.new("%PDF"), "application/pdf", original_filename: "offer.pdf"
    )

    post interview_note_images_path(job), params: { file: file }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(job.reload.note_images.count).to eq(0)
  end

  it "draws the picture in the timeline where the body embeds it" do
    post interview_note_images_path(job), params: { file: picture }
    path = interview_note_image_path(job.reload.note_images.sole.id)
    note!("Whiteboard they drew the pipeline on\n\n![Photo](#{path})\n\nFour channels, one model")

    get interview_path(job)

    expect(response.body).to include(%(<img src="#{path}" alt="Photo" loading="lazy">))
    expect(response.body).to include("Four channels, one model")
  end

  # The body is printed as typed, and an embed is part of that text until it is
  # proven to be one of his pictures. A path this app does not serve has nothing
  # to draw, so it reads as what he typed rather than as a broken picture.
  it "leaves an embed pointing somewhere else as the text he typed" do
    note!("![Photo](https://tracker.test/pixel.png)")

    get interview_path(job)

    expect(response.body).not_to include("<img")
    expect(response.body).to include("![Photo](https://tracker.test/pixel.png)")
  end

  it "still makes an ordinary markdown link in the same body clickable" do
    post interview_note_images_path(job), params: { file: picture }
    path = interview_note_image_path(job.reload.note_images.sole.id)
    note!("![Photo](#{path})\n[the posting](https://podium.test/jobs/1)")

    get interview_path(job)

    expect(response.body).to include(%(<img src="#{path}"))
    expect(response.body).to include(%(<a href="https://podium.test/jobs/1" target="_blank"))
  end
end
