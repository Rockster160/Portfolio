class CharacterBuilder
  attr_accessor :gender, :body, :clothing, :character_json

  def initialize(outfit={})
    change_to_outfit(outfit)
  end

  def change_outfit(outfit)
    return unless outfit.is_a?(Hash)

    @character_json.merge!(outfit.slice(:gender, :body, :clothing))
    @character_json[:clothing].merge!(outfit.except(:gender, :body, :clothing))

    set_required_attributes
    remove_invalid_attributes
    set_required_clothing

    self
  end

  def change_to_outfit(outfit)
    @character_json = empty_clothing_obj

    change_outfit(outfit || {})
  end

  def to_html
    body = html_for_component(gender: @gender, placement: "body", type: @body)
    character_html = [body]

    @character_json[:clothing].each do |placement, details|
      # placement = Symbol (ears, head, shoes, etc)
      # details = { type: String, color: String }
      cloth = { gender: gender, placement: placement, type: details[:type], color: details[:color] }
      character_html << html_for_component(cloth)
    end

    character_html.join("\n").html_safe
  end

  def to_json
    @character_json
  end

  private

  def self.character_outfits
    @@character_outfits ||= begin
      JSON.parse(File.read("lib/assets/valid_character_outfits.rb")).deep_symbolize_keys
    end
  end

  def permitted_outfits
    self.class.character_outfits
    # TODO: Filter these to only show the permitted ones
  end

  def genders
    [:male, :female]
  end

  def remove_invalid_attributes
    @character_json.slice!(:gender, :body, :clothing)
    @character_json[:gender] = nil unless genders.include?(@character_json[:gender])
    @character_json[:body] = nil unless permitted_outfits[@gender][:body].include?(@character_json[:body])

    new_clothing = {}
    @character_json[:clothing].each do |placement_str, details|
      placement = placement_str.to_s.to_sym rescue binding.pry
      details.symbolize_keys! rescue binding.pry
      if permitted_outfits.dig(@gender, placement, details[:type], details[:color])
        new_clothing[placement] = { type: details[:type], color: details[:color] }
      end
    end
    @character_json[:clothing] = new_clothing
  end

  def set_required_attributes
    @gender = @character_json[:gender] ||= genders.sample
    @body = @character_json[:body] ||= permitted_outfits[@gender][:body].sample
    @clothing = @character_json[:clothing] ||= {}
  end

  def set_required_clothing
    @character_json[:clothing][:torso] ||= begin
      type = permitted_outfits[@gender][:torso].keys.sample
      color = permitted_outfits[@gender][:torso][type].sample
      { type: type, color: color }
    end
    @character_json[:clothing][:legs] ||= begin
      type = permitted_outfits[@gender][:legs].keys.sample
      color = permitted_outfits[@gender][:legs][type].sample
      { type: type, color: color }
    end
    @clothing = @character_json[:clothing]
  end

  # component = { gender: Symbol, placement: Symbol, type: Symbol, color: Symbol }
  def html_for_component(component)
    gender, placement, type, color = component[:gender], component[:placement], component[:type], component[:color]
    path = [gender, placement, type, color].compact.join("/")
    return unless File.exists?("app/assets/images/rpg/#{path}.png")
    url = ActionController::Base.helpers.asset_path("rpg/#{path}.png")

    "<div class=\"#{placement}\" style=\"background-image: url('#{url}')\"></div>"
  end

  def empty_clothing_obj
    {
      gender: nil,
      body: nil,
      clothing: {
        # back: { type: "", color: "" },
        # beard: { type: "", color: "" },
      }
    }
  end

end
