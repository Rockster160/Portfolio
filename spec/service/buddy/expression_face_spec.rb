require "rails_helper"

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

      expect(convo.reload.buddy_expression).to be_in(%w[happy focused nerd encouraging])
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

  # The four drawn 2026-08-25. They are COMPLETE characters rather than the
  # eyes-and-mouth overlays the rest of Byte's set still is, so the body layer
  # is suppressed under them — and they were re-placed onto body.png's exact
  # footprint, or the pet would visibly jump size and position mid-conversation.
  describe "Byte's full-character faces" do
    full_body = %w[focused confused surprised playful]

    it "suppresses the body layer under each of them" do
      scss = Rails.root.join("app/assets/stylesheets/pages/byte.scss").read
      expect(scss[/\$byte_full_body:\s*([^;]+);/, 1].to_s.split).to match_array(full_body)
    end

    it "offers each of them as a mood the model can pick" do
      full_body.each { |face| expect(Buddy::Faces.selectable?(:byte, face)).to be(true) }
    end

    it "describes each of them for the prompt, or the model gets a bare name" do
      full_body.each { |face| expect(Buddy::Personality::FACE_HINTS[face.to_sym]).to be_present }
    end
  end
end
