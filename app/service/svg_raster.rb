# SVG → PNG for places that can only draw bitmaps (iOS widgets). Tries libvips,
# then rsvg-convert, then ImageMagick, so it works on whichever the machine has.
# Cached by the content's digest, which is also what callers put in the URL.
module SvgRaster
  module_function

  DEFAULT_SIZE = 600
  MAX_SIZE = 2_000

  def digest(svg)
    Digest::SHA256.hexdigest(svg.to_s).first(16)
  end

  def png(svg, width: nil, height: nil)
    width = size(width)
    height = height.present? ? size(height) : nil
    key = [:svg_raster, digest(svg), width, height].join(":")
    Rails.cache.fetch(key, expires_in: 7.days) { render(svg.to_s, width, height) }
  end

  def size(value)
    value = value.to_i
    value.positive? ? value.clamp(16, MAX_SIZE) : DEFAULT_SIZE
  end

  def render(svg, width, height)
    via_vips(svg, width, height) || via_command(svg, width, height)
  end

  def via_vips(svg, width, height)
    require "vips"
    image = Vips::Image.svgload_buffer(svg)
    scale = width.to_f / image.width
    scale = [scale, height.to_f / image.height].min if height
    Vips::Image.svgload_buffer(svg, scale: scale).write_to_buffer(".png")
  rescue LoadError, StandardError
    nil
  end

  def via_command(svg, width, height)
    rsvg = ["rsvg-convert", "--format=png", "--width=#{width}"]
    rsvg += ["--height=#{height}", "--keep-aspect-ratio"] if height
    magick = ["convert", "-background", "none", "-density", "300", "svg:-"]
    magick += ["-resize", "#{width}x#{height}", "png:-"]

    [rsvg, magick].each { |command|
      output = capture(command, svg)
      return output if output.present?
    }
    nil
  end

  def capture(command, svg)
    output, status = Open3.capture2(*command, stdin_data: svg, binmode: true)
    status.success? ? output : nil
  rescue Errno::ENOENT
    nil
  end
end
