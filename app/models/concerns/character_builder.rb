class CharacterBuilder
  using CoreExtensions
  attr_accessor :gender, :body, :clothing, :character_json

  def initialize(outfit, options={})
    change_to_outfit(outfit)
  end

  def change_outfit(outfit)
    return unless outfit.is_a?(Hash)
    outfit.deep_symbolize_keys!

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

  def self.required_placements
    ["body", "torso", "legs"]
  end

  def self.character_outfits
    @@character_outfits ||= begin
      HashWithIndifferentAccess.new(JSON.parse(File.read("lib/assets/valid_character_outfits.rb")))
    end
  end

  def self.outfit_should_reject?(outfit, item)
    return true if item == "*"

    if outfit.is_a?(Hash)
      item.keys.include?(item) || item.values.include?(item)
    else
      outfit.include?(item.to_s)
    end
  end

  def self.default_outfits
    @@default_outfits ||= begin
      outfits = character_outfits.dup

      blacklist = {
        both: {
          weapons: [ "*" ],
          arms: [ "*" ],
          body: [ :orc, :red_orc ],
          torso: [ :plate, :chain, :gold ]
        },
        male: {
          body: [ :skeleton ],
          beard: [ :fiveoclock ],
          eyes: {
            colors: [ :casting_eyeglow_skeleton ]
          }
        },
        female: {}
      }

      blacklist[:male].deep_merge!(blacklist[:both]) { |key, this_val, other_val| this_val + other_val }
      blacklist[:female].deep_merge!(blacklist[:both]) { |key, this_val, other_val| this_val + other_val }
      blacklist.except!(:both)

      blacklist.all_paths.each do |*path, item|
        if path.any?
          outfits.dig(*path).reject! { |outfit| outfit_should_reject?(outfit, item) }
        else
          outfits.reject! { |outfit| outfit_should_reject?(outfit, item) }
        end
      end

      outfits.clean!
    end
  end

  def default_outfits
    self.class.default_outfits
  end

  def genders
    ["male", "female"]
  end

  def remove_invalid_attributes
    @character_json.slice!(:gender, :body, :clothing)
    @character_json[:gender] = nil unless genders.include?(@character_json[:gender])
    @character_json[:body] = nil unless default_outfits[@gender][:body].include?(@character_json[:body])

    new_clothing = {}
    @character_json[:clothing].each do |placement_str, details|
      placement = placement_str.to_s.to_sym
      details.symbolize_keys!
      if default_outfits.dig(@gender, placement, details[:type])&.include?(details[:color])
        new_clothing[placement] = { type: details[:type], color: details[:color] }
      end
    end
    @character_json[:clothing] = new_clothing
  end

  def set_required_attributes
    @gender = @character_json[:gender] ||= genders.sample
    @body = @character_json[:body] ||= default_outfits[@gender][:body].sample
    @clothing = @character_json[:clothing] ||= {}
  end

  def set_required_clothing
    @character_json[:clothing][:torso] ||= begin
      type = default_outfits[@gender][:torso].keys.sample rescue binding.pry
      color = default_outfits[@gender][:torso][type].sample
      { type: type, color: color }
    end
    # FIXME: Don't need pants if using a Robe or Dress
    @character_json[:clothing][:legs] ||= begin
      type = default_outfits[@gender][:legs].keys.sample
      color = default_outfits[@gender][:legs][type].sample
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
