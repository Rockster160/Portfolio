require "rails_helper"
require "chunky_png"

RSpec.describe Buddy::ExpressionState do
  before { allow(MonitorChannel).to receive(:broadcast_to) }

  # Pet state (theme + expression) now lives on the buddy-mode conversation,
  # not the user — so every case runs against a buddy conversation.
  def buddy_convo(user, theme)
    convo = user.byte_conversations.create!(mode: :buddy)
    convo.update!(buddy_theme: theme)
    convo
  end

  it "accepts only faces the conversation's theme actually has" do
    byte = buddy_convo(User.me, "byte")
    moss = buddy_convo(create(:user), "moss")

    described_class.set(byte, "nerd")            # Byte has nerd
    expect(byte.reload.buddy_expression).to eq("nerd")

    described_class.set(byte, "grin")            # Byte has no grin → refused
    expect(byte.reload.buddy_expression).to eq("nerd")

    described_class.set(moss, "grin")            # Moss has grin
    expect(moss.reload.buddy_expression).to eq("grin")

    described_class.set(moss, "nerd")            # Moss has no nerd → refused
    expect(moss.reload.buddy_expression).to eq("grin")
  end

  it "shows 'thinking' as a transient overlay without persisting it as the mood" do
    convo = buddy_convo(create(:user), "byte")
    convo.update_column(:buddy_expression, "happy")

    # turn_started broadcasts a transient overlay but must NOT write the column
    # (the persistent mood stays put underneath the thinking face).
    described_class.transition!(convo, :turn_started)
    expect(convo.reload.buddy_expression).to eq("happy")
    expect(MonitorChannel).to have_received(:broadcast_to).with(
      convo.user, hash_including(data: hash_including(expression: "thinking", transient: true))
    )
  end

  it "keeps the mood put on settle — no drifting back to a default" do
    convo = buddy_convo(create(:user), "byte")
    convo.update_column(:buddy_expression, "nerd")

    # Every non-turn-start event just settles: re-broadcasts the STORED mood
    # (clearing any thinking overlay) without changing it. This is the fix for
    # "the face changed for a second then reverted".
    %i[turn_ended_clean proposals_awaiting proposals_executed proposals_cancelled tool_failed idle_long].each do |event|
      described_class.transition!(convo, event)
      expect(convo.reload.buddy_expression).to eq("nerd"), "#{event} moved the mood"
    end
  end

  it "refuses `thinking` as a worn face — it is transitional, never a mood" do
    convo = buddy_convo(User.me, "byte")
    convo.update_column(:buddy_expression, "happy")

    described_class.wear(convo, "thinking")

    expect(convo.reload.buddy_expression).to eq("happy")   # unchanged — rejected
  end

  # Faces are driven entirely off the art on disk now: the hero paints the
  # resolved image for the current expression (ByteHelper#buddy_face_paths feeds
  # buddy/hero.js), with no per-theme list in the stylesheet to keep in step. So
  # the invariants are about the folder and the sentiment map, not CSS — and
  # they hold for every companion, including one added with no code touched.
  describe "the face art and the sentiment map" do
    Buddy::Themes.all.each_key do |theme|
      # The resting default, the first paint, and the resolver's fallback for an
      # expression a pet has no art for all land on neutral (Buddy::Faces.default
      # and ByteHelper#buddy_face_url) — so every pet must have it or the hero can
      # render blank, which is exactly how a theme with no face CSS used to fail.
      it "#{theme} has a neutral face to rest on and fall back to" do
        expect(Buddy::Faces.valid?(theme, :neutral)).to be(true)
      end

      # The prose half of the profile. Each emotion carries its own summary on
      # the companion, right beside its axes, so a face with numbers and no
      # sentence can't drift in unnoticed.
      it "#{theme} describes every face it can wear" do
        missing = Buddy::Faces.selectable(theme).reject { |f| Buddy::Faces.summary(f, theme) }
        expect(missing).to be_empty
      end
    end

    # The check-in is the one expression change with no model turn behind it: the
    # person taps how they're doing and the pet's face answers. The companions
    # drawn with a full set carry both halves of that directly; the ones with
    # holes fall back through the sentiment picker to their nearest face instead.
    it "every full-set companion can wear both check-in faces" do
      %w[byte moss glimmer suki kumoko mocha ghosty].each do |theme|
        %i[happy sad].each do |face|
          expect(Buddy::Faces.valid?(theme, face)).to be(true), "#{theme} cannot render #{face}"
        end
      end
    end
  end

  # Byte used to be drawn in two layers: a faceless `body.png` slime with the
  # eyes and mouth as a small transparent overlay on top. Every face is a
  # COMPLETE character now — slime, expression, bubbles, puddle, the lot — which
  # is what Moss, Suki and Glimmer always were, and the body layer is gone.
  #
  # Two things have to hold for a set drawn that way, and neither is visible in
  # a filename. A face that still carries only the eyes and mouth would render
  # as features floating on nothing; and a face placed anywhere but on the
  # others\' footprint makes the pet jump size and position as its mood changes.
  describe "Byte's full-character faces" do
    faces = Rails.root.glob("app/assets/images/buddy/byte/face_*.png")

    def alpha_rows(image)
      (0...image.height).select { |y|
        (0...image.width).any? { |x| ChunkyPNG::Color.a(image[x, y]) > 128 }
      }
    end

    it "draws a whole character in every one, not an overlay" do
      # Measured on a downsample — the question is 3% of the frame versus 30%,
      # and decoding half a million pixels a face to answer it is a waste.
      thin = faces.filter_map { |path|
        small = ChunkyPNG::Image.from_file(path).resample_nearest_neighbor(180, 180)
        cover = small.pixels.count { |px| ChunkyPNG::Color.a(px) > 128 } / (180.0 * 180)
        next if cover >= 0.25

        "#{path.basename} covers #{(cover * 100).round(1)}% of its frame"
      }

      expect(thin).to eq([]), "these look like the old eyes-and-mouth overlays:\n#{thin.join("\n")}"
    end

    it "stands every one on the same baseline" do
      # 555 on the 720 canvas, inherited from the `body.png` the first four were
      # aligned to. The number matters less than every face sharing it.
      off = faces.filter_map { |path|
        bottom = alpha_rows(ChunkyPNG::Image.from_file(path)).last
        next if (553..559).cover?(bottom)

        "#{path.basename} sits its puddle at y=#{bottom}"
      }

      expect(off).to eq([]), "these make the pet hop when the mood changes:\n#{off.join("\n")}"
    end

    it "keeps the body layer empty for every theme" do
      scss = Rails.root.join("app/assets/stylesheets/pages/byte.scss").read
      body = scss.scan(/\.byte-buddy-body\s*\{[^}]*\}/m).join
      expect(body).not_to include("image-url")
    end
  end
end
