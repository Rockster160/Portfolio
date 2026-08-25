require "rails_helper"

# Photos on a box, from the Inventory app.
#
# The upload goes through ByteImageIntake rather than straight to the
# attachment, so the bar an image has to clear here is the one it clears in
# Byte: the same type allowlist, the same size ceiling, the same HEIC
# transcode. Two places deciding separately what counts as a picture is two
# places for them to disagree, and the disagreement only ever shows up as a
# broken thumbnail nobody can explain.
RSpec.describe "Inventory photos", type: :request do
  let(:user) { create(:user) }
  let!(:tote) { create(:box, user: user, name: "Camping Tote") }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  def jpeg(name="tote.jpg")
    file = Tempfile.new([name, ".jpg"])
    file.binmode
    file.write("\xFF\xD8\xFF\xE0fake jpeg bytes".b)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "image/jpeg", original_filename: name)
  end

  def body
    response.parsed_body["data"]
  end

  it "attaches a photo and hands the box back with it on" do
    post attach_image_inventory_path, params: { box_id: tote.param_key, files: [jpeg] },
      headers: { "ACCEPT" => "application/json" }

    expect(response).to have_http_status(:ok)
    expect(tote.reload.images.count).to eq(1)
    expect(body["images"].first["filename"]).to eq("tote.jpg")
    expect(body["images"].first["url"]).to be_present
  end

  it "finds the box by the handle off its label, digits and all" do
    # `set_param_key` only mints one when it's blank, so a handed-in key is
    # kept - which is what lets this pin a key holding both letters a label
    # never carries. Somebody reading "0" and "1" off a printed label lands on
    # the O and the I that were really minted.
    labelled = create(:box, user: user, name: "Odds And Ends", param_key: "OIXY")

    post attach_image_inventory_path, params: { box_id: "01xy", files: [jpeg] },
      headers: { "ACCEPT" => "application/json" }

    expect(labelled.reload.images.count).to eq(1)
  end

  it "refuses something that isn't a picture on the same terms Byte does" do
    file = Tempfile.new(["notes", ".txt"])
    file.write("not an image")
    file.rewind

    post attach_image_inventory_path, params: {
      box_id: tote.param_key,
      files:  [Rack::Test::UploadedFile.new(file.path, "text/plain", original_filename: "notes.txt")],
    }, headers: { "ACCEPT" => "application/json" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(tote.reload.images).to be_empty
  end

  it "removes one photo and leaves the rest" do
    keep = tote.images.create!(user: user)
    keep.file.attach(io: StringIO.new("\xFF\xD8keep".b), filename: "keep.jpg", content_type: "image/jpeg")
    drop = tote.images.create!(user: user)
    drop.file.attach(io: StringIO.new("\xFF\xD8drop".b), filename: "drop.jpg", content_type: "image/jpeg")

    delete remove_image_inventory_path, params: { box_id: tote.param_key, image_id: drop.id },
      headers: { "ACCEPT" => "application/json" }

    expect(response).to have_http_status(:ok)
    expect(tote.reload.images.map(&:id)).to eq([keep.id])
  end

  it "says so rather than silently doing nothing when the photo isn't there" do
    delete remove_image_inventory_path, params: { box_id: tote.param_key, image_id: 999_999 },
      headers: { "ACCEPT" => "application/json" }

    expect(response).to have_http_status(:not_found)
  end

  it "does not take a photo off somebody else's box" do
    theirs = create(:box, user: create(:user), name: "Their Tote")
    image = theirs.images.create!(user: theirs.user)
    image.file.attach(io: StringIO.new("\xFF\xD8theirs".b), filename: "t.jpg", content_type: "image/jpeg")

    expect {
      delete remove_image_inventory_path, params: { box_id: theirs.param_key, image_id: image.id },
        headers: { "ACCEPT" => "application/json" }
    }.not_to change(BoxImage, :count)
  end
end
