module Buddy
  # Reverses a single Byte mutation from a `revert` descriptor that the tool
  # stashed on its execute result (which the executor persists onto the
  # proposal button). This is the "lightweight recent-undo": no history table,
  # just the descriptor on the proposal.
  #
  # Descriptor shape (all string/symbol-indifferent):
  #   { op: "created", model: "ActionEvent", id: 42, summary: "..." }
  #   { op: "updated", model: "AgendaItem",  id: 7,  before: {...}, summary }
  #   { op: "recreated", model: "ActionEvent", attrs: {...}, summary }
  #
  # Deliberately narrow: only models whose reversal is clean and side-effect
  # free. Chore completions keep their own dedicated undo tool.
  module Reverter
    module_function

    MODELS = { "ActionEvent" => "ActionEvent", "AgendaItem" => "AgendaItem" }.freeze

    def reversible?(revert)
      r = normalize(revert)
      return false if r[:op].blank?

      r[:op].to_s == "recreated" ? MODELS.key?(r[:model].to_s) : (r[:id].present? && MODELS.key?(r[:model].to_s))
    end

    # Reverses the descriptor. Returns a short human summary; raises on failure.
    def call(revert)
      r = normalize(revert)
      case r[:op].to_s
      when "created"   then remove(r)
      when "updated"   then revert_update(r)
      when "recreated" then recreate(r)
      else raise "nothing here to undo"
      end
      r[:summary].to_s.presence || "Undone."
    end

    def normalize(revert)
      revert.respond_to?(:with_indifferent_access) ? revert.with_indifferent_access : {}
    end

    def klass(name)
      raise "can't undo #{name}" unless MODELS.key?(name.to_s)

      name.to_s.constantize
    end

    def find!(r)
      rec = klass(r[:model]).find_by(id: r[:id])
      raise "it's already gone" if rec.nil?

      rec
    end

    # Undo a create → remove what was just added (soft where the model allows).
    def remove(r)
      rec = find!(r)
      case r[:model].to_s
      when "ActionEvent" then rec.destroy!
      when "AgendaItem"  then rec.update!(status: :cancelled, cancelled_at: Time.current)
      end
    end

    # Undo an edit → put the previous values back.
    def revert_update(r)
      before = (r[:before] || {}).to_h
      raise "no prior values recorded" if before.empty?

      find!(r).update!(before)
    end

    # Undo a hard delete → recreate from the stored attributes.
    def recreate(r)
      attrs = (r[:attrs] || {}).to_h
      raise "nothing to recreate" if attrs.empty?

      klass(r[:model]).create!(attrs)
    end

    # ---- finding + performing the most-recent undo (for the `undo` tool) ----

    # The newest executed proposal button in the conversation that carries a
    # still-un-undone, reversible `revert` descriptor. Returns
    # { action_id:, button_id:, summary: } or nil.
    def most_recent(conversation)
      return nil if conversation.nil?

      actions = ByteAction.where(byte_conversation_id: conversation.id, tool_name: "buddy_proposals").order(created_at: :desc).limit(25)
      actions.each do |action|
        Array(action.buttons).reverse_each do |btn|
          result = btn["result"]
          next unless result.is_a?(Hash)

          revert = result["revert"]
          next if revert.blank? || result["undone"]
          next unless reversible?(revert)

          return { action_id: action.id, button_id: btn["id"], summary: normalize(revert)[:summary].to_s.presence || "your last change" }
        end
      end
      nil
    end

    # Reverse the button's stashed descriptor and mark it undone so a second
    # undo moves on to the previous action.
    def perform!(byte_action_id, button_id)
      action  = ByteAction.find(byte_action_id)
      buttons = Array(action.buttons).map(&:dup)
      btn     = buttons.find { |b| b["id"].to_i == button_id.to_i }
      raise "can't find that action" if btn.nil?

      result = (btn["result"] || {}).dup
      raise "that's already been undone" if result["undone"]

      summary = call(result["revert"])
      result["undone"] = true
      btn["result"] = result
      action.update!(buttons: buttons)
      { summary: summary }
    end
  end
end
