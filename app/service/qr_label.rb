class QrLabel < Qr
  INCH_TO_MM = 25.4

  FONT_5x7 = { # rubocop:disable Naming/ConstantName
    "a" => "00000.00000.01110.00001.01111.10001.01111",
    "b" => "10000.10000.11110.10001.10001.10001.11110",
    "c" => "00000.00000.01111.10000.10000.10000.01111",
    "d" => "00001.00001.01111.10001.10001.10001.01111",
    "e" => "00000.00000.01110.10001.11111.10000.01110",
    "f" => "00011.00100.01110.00100.00100.00100.00100",
    "g" => "00000.00000.01111.10001.01111.00001.01110",
    "h" => "10000.10000.11110.10001.10001.10001.10001",
    "i" => "00100.00000.01100.00100.00100.00100.01110",
    "j" => "00010.00000.00110.00010.00010.10010.01100",
    "k" => "10000.10000.10010.10100.11000.10100.10010",
    "l" => "11000.01000.01000.01000.01000.01000.11100",
    "m" => "00000.00000.11010.10101.10101.10101.10101",
    "n" => "00000.00000.11110.10001.10001.10001.10001",
    "o" => "00000.00000.01110.10001.10001.10001.01110",
    "p" => "00000.00000.11110.10001.11110.10000.10000",
    "q" => "00000.00000.01111.10001.01111.00001.00001",
    "r" => "00000.00000.10111.11000.10000.10000.10000",
    "s" => "00000.00000.01111.10000.01110.00001.11110",
    "t" => "00100.00100.01110.00100.00100.00100.00011",
    "u" => "00000.00000.10001.10001.10001.10011.01101",
    "v" => "00000.00000.10001.10001.10001.01010.00100",
    "w" => "00000.00000.10001.10101.10101.10101.01010",
    "x" => "00000.00000.10001.01010.00100.01010.10001",
    "y" => "00000.00000.10001.10001.01111.00001.01110",
    "z" => "00000.00000.11111.00010.00100.01000.11111",
    "A" => "01110.10001.10001.11111.10001.10001.10001",
    "B" => "11110.10001.11110.10001.10001.10001.11110",
    "C" => "01110.10001.10000.10000.10000.10001.01110",
    "D" => "11110.10001.10001.10001.10001.10001.11110",
    "E" => "11111.10000.11110.10000.10000.10000.11111",
    "F" => "11111.10000.11110.10000.10000.10000.10000",
    "G" => "01111.10000.10000.10111.10001.10001.01111",
    "H" => "10001.10001.11111.10001.10001.10001.10001",
    "I" => "11111.00100.00100.00100.00100.00100.11111",
    "J" => "11111.00010.00010.00010.00010.10010.01100",
    "K" => "10001.10010.10100.11000.10100.10010.10001",
    "L" => "10000.10000.10000.10000.10000.10000.11111",
    "M" => "10001.11011.10101.10101.10001.10001.10001",
    "N" => "10001.11001.10101.10011.10001.10001.10001",
    "O" => "01110.10001.10001.10001.10001.10001.01110",
    "P" => "11110.10001.10001.11110.10000.10000.10000",
    "Q" => "01110.10001.10001.10001.10101.10010.01101",
    "R" => "11110.10001.10001.11110.10100.10010.10001",
    "S" => "01111.10000.10000.01110.00001.00001.11110",
    "T" => "11111.00100.00100.00100.00100.00100.00100",
    "U" => "10001.10001.10001.10001.10001.10001.01110",
    "V" => "10001.10001.10001.10001.01010.01010.00100",
    "W" => "10001.10001.10001.10101.10101.11011.10001",
    "X" => "10001.10001.01010.00100.01010.10001.10001",
    "Y" => "10001.10001.01010.00100.00100.00100.00100",
    "Z" => "11111.00001.00010.00100.01000.10000.11111",
    "0" => "01110.10001.10011.10101.11001.10001.01110",
    "1" => "00100.01100.00100.00100.00100.00100.01110",
    "2" => "01110.10001.00001.00010.00100.01000.11111",
    "3" => "01110.10001.00001.01110.00001.10001.01110",
    "4" => "00010.00110.01010.10010.11111.00010.00010",
    "5" => "11111.10000.11110.00001.00001.10001.01110",
    "6" => "00110.01000.10000.11110.10001.10001.01110",
    "7" => "11111.00001.00010.00100.01000.01000.01000",
    "8" => "01110.10001.10001.01110.10001.10001.01110",
    "9" => "01110.10001.10001.01111.00001.00010.01100",
    "-" => "00000.00000.00000.11111.00000.00000.00000",
    "_" => "00000.00000.00000.00000.00000.00000.11111",
    "." => "00000.00000.00000.00000.00000.01100.01100",
    ":" => "00000.01100.01100.00000.01100.01100.00000",
    "/" => "00001.00010.00100.01000.10000.00000.00000",
    " " => "00000.00000.00000.00000.00000.00000.00000",
    "?" => "11111.11111.11111.11111.11111.11111.11111",
  }.freeze

  def self.card(url, title:, dpi: 203, pad_mm: 0.8, title_scale: 3, url_scale: 2)
    new(url.gsub(/https?:\/\//, "").gsub(":3141", "")).card(
      url.gsub(/https?:\/\//, "").gsub(":3141", ""),
      title:       title,
      dpi:         dpi,
      pad_mm:      pad_mm,
      title_scale: title_scale,
      url_scale:   url_scale,
    )
  end

  def card(url, title:, dpi:, pad_mm:, title_scale:, url_scale:)
    w_px = (1.18 * dpi).round
    h_px = (1.57 * dpi).round
    pad  = (pad_mm * dpi / INCH_TO_MM).round

    inner_w = w_px - (pad * 2)
    inner_h = h_px - (pad * 2)
    qr_text_gap = 6

    qr_img = @qr.as_png(
      size:           w_px - pad,
      border_modules: 0,
      color_mode:     ::ChunkyPNG::COLOR_GRAYSCALE,
      color:          "black",
      fill:           "white",
    )

    text_img = render_text_block(
      title:       title,
      url:         url,
      max_width:   inner_w,
      title_scale: title_scale.floor,
      url_scale:   url_scale.floor,
      gap:         qr_text_gap,
    )

    avail_h = inner_h - qr_img.height - qr_text_gap
    if text_img.width > inner_w || text_img.height > avail_h
      # if too wide, shrink scales proportionally (integer floor)
      w_ratio = inner_w.to_f / text_img.width
      h_ratio = avail_h.to_f / text_img.height
      shrink  = [w_ratio, h_ratio, 1.0].min
      new_t   = (title_scale * shrink).floor.clamp(1, title_scale)
      new_u   = (url_scale * shrink).floor.clamp(1, url_scale)
      text_img = render_text_block(
        title:       title,
        url:         url,
        max_width:   inner_w,
        title_scale: new_t,
        url_scale:   new_u,
        gap:         qr_text_gap,
      )
    end

    canvas = ::ChunkyPNG::Image.new(w_px, h_px, ::ChunkyPNG::Color::WHITE)

    # Center horizontally
    x_qr   = pad + ((inner_w - qr_img.width) / 2)
    x_text = pad + ((inner_w - text_img.width) / 2)

    # Text goes at the top, QR below
    y_qr   = h_px - pad - qr_img.height
    y_text = (y_qr / 2) - (text_img.height / 2) + (pad / 2)

    canvas.replace(qr_img, x_qr, y_qr)
    canvas.replace(text_img, x_text, y_text)

    canvas.to_blob
  end

  private

  def render_text_block(title:, url:, max_width:, title_scale:, url_scale:, gap:)
    title_lines = wrap(title, max_cols(max_width, title_scale))
    url_lines   = wrap(url, max_cols(max_width, url_scale))

    title_img = render_lines(title_lines, title_scale, max_width)
    url_img   = render_lines(url_lines, url_scale, max_width)

    h = title_img.height + gap + url_img.height
    out = ::ChunkyPNG::Image.new(max_width, h, ::ChunkyPNG::Color::WHITE)
    out.replace(title_img, 0, 0)
    out.replace(url_img, 0, title_img.height + gap)
    out
  end

  def render_lines(lines, scale, max_width)
    line_h = 7 * scale
    total_h = (lines.size * line_h) + ((lines.size - 1) * scale)
    img = ::ChunkyPNG::Image.new(max_width, total_h, ::ChunkyPNG::Color::WHITE)

    y = 0
    lines.each do |line|
      w = text_px_width(line, scale)
      x = (max_width - w) / 2
      draw_text(img, line, x, y, scale)
      y += line_h + scale
    end
    img
  end

  def max_cols(max_width, scale)
    cols_per_char = glyph_cols("A")
    char_w = (cols_per_char * scale) + scale
    [1, (max_width / char_w)].max
  end

  def wrap(text, max_cols)
    words = text.split(/\s+/)
    lines = []
    line = ""

    words.each do |w|
      if line.empty?
        line = w
      elsif (line.length + 1 + w.length) <= max_cols
        line << " " << w
      else
        lines << line
        line = w
      end
    end
    lines << line unless line.empty?
    lines
  end

  def text_px_width(text, scale)
    text.chars.sum { |ch| (glyph_cols(ch) * scale) + scale } - scale
  end

  def glyph_cols(ch)
    (FONT_5x7[ch] || FONT_5x7["?"]).split(".").first.size
  end

  def draw_text(img, text, x, y, scale)
    color = ::ChunkyPNG::Color::BLACK
    text.chars.each do |ch|
      pattern = FONT_5x7[ch] || FONT_5x7["?"]
      cols = pattern.split(".").first.size
      draw_glyph(img, pattern, x, y, scale, color)
      x += (cols * scale) + scale
    end
  end

  def draw_glyph(img, pattern, x, y, scale, color)
    rows = pattern.split(".")
    rows.each_with_index do |row, ry|
      row.chars.each_with_index do |bit, rx|
        next unless bit == "1"

        sx = x + (rx * scale)
        sy = y + (ry * scale)
        img.rect(sx, sy, sx + scale - 1, sy + scale - 1, color, color)
      end
    end
  end
end
