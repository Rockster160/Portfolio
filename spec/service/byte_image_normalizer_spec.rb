require "rails_helper"

RSpec.describe ByteImageNormalizer do
  def png_bytes(width: 4, height: 4)
    ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::WHITE).to_blob
  end

  # The real thing the controller receives — a tempfile on disk, which is what
  # ImageMagick is handed a path to.
  def upload(bytes:, type:, name:)
    file = Tempfile.new(["upload", File.extname(name)], binmode: true)
    file.write(bytes)
    file.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: name, type: type)
  end

  def png(name: "shot.png")
    upload(bytes: png_bytes, type: "image/png", name: name)
  end

  describe "formats every model already reads" do
    it "stores a normal PNG untouched" do
      result = described_class.call(png)

      expect(result).to be_ok
      expect(result.content_type).to eq("image/png")
      expect(result.filename).to eq("shot.png")
    end
  end

  describe "formats no model reads" do
    # HEIC is the whole reason this service exists: OpenAI, Anthropic, Chrome and
    # Firefox all refuse it, and an unreadable image doesn't just get skipped -
    # it 400s the entire turn.
    it "transcodes HEIC to JPEG and renames it to match" do
      allow(described_class).to receive(:jpeg).and_call_original
      heic = upload(bytes: png_bytes, type: "image/heic", name: "IMG_0042.HEIC")

      result = described_class.call(heic)

      expect(result).to be_ok
      expect(result.content_type).to eq("image/jpeg")
      expect(result.filename).to eq("IMG_0042.jpg")
    end

    # ImageMagick may be missing, or built without the heic delegate. Storing the
    # HEIC anyway would trade a clear refusal now for a broken turn later.
    it "refuses rather than storing something unreadable when the convert fails" do
      allow(described_class).to receive(:jpeg).and_return(nil)
      heic = upload(bytes: png_bytes, type: "image/heic", name: "IMG_0042.HEIC")

      result = described_class.call(heic)

      expect(result).not_to be_ok
      expect(result.error).to match(/HEIC/)
    end
  end

  describe "images too heavy to send as-is" do
    before { stub_const("#{described_class}::RECOMPRESS_OVER", 1) }

    it "re-encodes past the size ceiling, since OpenAI caps a single image at 20MB" do
      result = described_class.call(png)

      expect(result.content_type).to eq("image/jpeg")
      expect(result.filename).to eq("shot.jpg")
    end

    # A readable format that fails to convert is still readable - keeping the
    # original costs bandwidth, but the turn works.
    it "keeps the original when the convert fails" do
      allow(described_class).to receive(:jpeg).and_return(nil)

      result = described_class.call(png)

      expect(result).to be_ok
      expect(result.content_type).to eq("image/png")
    end
  end
end
