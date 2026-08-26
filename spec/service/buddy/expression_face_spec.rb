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

  it "refuses a delivered [[mood: thinking]] — thinking is not a selectable face" do
    convo = buddy_convo(User.me, "byte")
    convo.update_column(:buddy_expression, "happy")

    Buddy::SideEffects.apply_mood(convo, "thinking")

    expect(convo.reload.buddy_expression).to eq("happy")   # unchanged — rejected
  end

  # Prod 4594. Byte ran the camera function, the function came back "couldn't
  # get a frame", and the pet — resting on neutral because the model chose no
  # face — was handed a random pleased one. It drew `uwu`: an eyes-closed,
  # open-mouthed laugh, over a shrug.
  describe "reacting to an action" do
    it "wears a miss when the turn didn't land" do
      convo = buddy_convo(User.me, "byte")
      convo.update_column(:buddy_expression, "neutral")

      described_class.react!(convo, ok: false)

      expect(convo.reload.buddy_expression).to be_in(%w[confused annoyed sad])
    end

    it "wears something pleased when it did" do
      convo = buddy_convo(create(:user), "byte")
      convo.update_column(:buddy_expression, "neutral")

      described_class.react!(convo)

      expect(convo.reload.buddy_expression).to be_in(%w[happy neutral_blush nerd])
    end

    # A face the model picked is a read of the room. This is a floor under a
    # resting pet, never a correction of a deliberate choice.
    it "leaves a face the model chose alone, either way" do
      convo = buddy_convo(create(:user), "byte")
      convo.update_column(:buddy_expression, "crying")

      described_class.react!(convo, ok: false)

      expect(convo.reload.buddy_expression).to eq("crying")
    end
  end

  # `$<theme>_expressions` in byte.scss names each file explicitly, and asset
  # precompile FAILS on a name with no image behind it. Buddy::Faces reads the
  # same directory, so the two must agree in both directions: a face on disk and
  # not in the list is unreachable, a face listed and not on disk breaks deploy.
  describe "the SCSS lists and the art on disk" do
    scss = Rails.root.join("app/assets/stylesheets/pages/byte.scss").read

    %w[byte moss glimmer suki].each do |theme|
      listed = scss[/\$#{theme}_expressions:\s*([^;]+);/, 1].to_s.split.map(&:to_sym)

      it "#{theme} lists every face it has, and has every face it lists" do
        expect(listed.sort).to eq(Buddy::Faces.all(theme).sort)
      end

      it "#{theme}'s aliases all point at art that exists" do
        block = scss[/\$#{theme}_expr_aliases:\s*\((.*?)\);/m, 1].to_s
        targets = block.scan(/"[^"]+":\s*"([^"]+)"/).flatten.map(&:to_sym)
        expect(targets - Buddy::Faces.all(theme)).to be_empty
      end

      # A face with no hint reaches the model as a bare name. It stays in the
      # list, so it can still be picked — picked on the strength of the word
      # alone, which is how a theme ends up wearing something nobody meant.
      it "#{theme} describes every face it offers" do
        missing = Buddy::Faces.selectable(theme).reject { |f| Buddy::Personality::FACE_HINTS[f] }
        expect(missing).to be_empty
      end
    end

    # The check-in is the one expression change with no model turn behind it:
    # the person taps how they're doing and the pet's face answers. `set`
    # validates against the art on disk and does nothing at all when it's
    # missing, so a theme without one of these fails SILENTLY — Suki went
    # without `sad` for weeks and a tap on "rough" moved nothing.
    it "every theme can wear both check-in faces" do
      %w[byte moss glimmer suki].each do |theme|
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
