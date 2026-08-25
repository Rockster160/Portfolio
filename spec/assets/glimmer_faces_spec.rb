require "rails_helper"
require "chunky_png"

# Glimmer's nine poses were spliced out of one sheet, and the splice left four
# of them framed high in the 500×500 canvas — neutral sat with its content
# centered at 40% and a fifth of the frame empty below it. Since the hero draws
# the face layer `background-size: contain` into a square box, that framing IS
# the vertical position: she rendered noticeably above the middle of her half of
# the kiosk, and jumped when her mood changed to one of the well-framed poses.
#
# Re-splicing the sheet is the way that comes back, so the invariant is checked
# rather than left to the eye. Scoped to Glimmer deliberately: Byte's face PNG
# is a small overlay on a separate body layer, and Moss and Suki bake their
# characters at their own framings.
RSpec.describe "Glimmer face assets" do
  faces = Rails.root.glob("app/assets/images/buddy/glimmer/face_*.png").sort

  # Alpha over this counts as drawn — the art carries a faint glow halo that
  # would otherwise stretch every bounding box to the full canvas.
  alpha_floor = 8

  # Where the drawn content's midpoint has to land, as a fraction of the canvas.
  # The poses that always looked right cluster at 51–54%; this is that band with
  # a little room either side.
  center_band = (0.48..0.56)

  def content_center(path, alpha_floor)
    image = ChunkyPNG::Image.from_file(path)
    rows = (0...image.height).select { |y|
      (0...image.width).any? { |x| ChunkyPNG::Color.a(image[x, y]) > alpha_floor }
    }
    raise "#{path.basename} is fully transparent" if rows.empty?

    (rows.first + rows.last) / 2.0 / image.height
  end

  # The roster and the framing together, because they're one question asked of
  # one set of files: are the poses the stylesheet wires up all here, and do
  # they all sit in the middle of their canvas. One example decoding thirteen
  # PNGs rather than thirteen; the report is the same either way, because a
  # failure lists every pose that drifted and where it landed.
  it "ships the poses the stylesheet wires up, each centered in its canvas" do
    poses    = faces.map { |p| p.basename(".png").to_s.delete_prefix("face_") }
    expected = "content crying dismayed focused grin happy loving neutral " \
               "sad sleeping star surprised thinking"
    expect(poses).to match_array(expected.split)

    drifted = faces.filter_map { |path|
      center = content_center(path, alpha_floor)
      next if center_band.cover?(center)

      "#{path.basename} draws its content centered at #{(center * 100).round(1)}% of the canvas"
    }

    expect(drifted).to eq([]), "these render that far off the middle of the hero:\n#{drifted.join("\n")}"
  end
end
