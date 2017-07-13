class CharacterBuilder
  using CoreExtensions
  attr_accessor :gender, :body, :clothing, :character_json

  def initialize(outfit, options={})
    change_to_outfit(outfit)
    change_random if options[:random]
  end

  def change_outfit(outfit)
    outfit = outfit.is_a?(Hash) ? outfit : {}
    outfit = outfit.deep_symbolize_keys
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

  # HASH: Keys represent the placement of clothing, values are the
  #   chance to use it between 0 and 1 (0.5 is 50% chance)
  # ARRAY 100% chance to randomize each placement passed in.
  def change_random(*placements)
    @gender = @character_json[:gender] = genders.sample
    @body = @character_json[:body] = default_outfits[@gender][:body].sample
    @clothing = {}

    placements = default_outfits[@gender]
    placements.each do |placement, styles|
      next if placement.to_s == "body"
      next if placement.to_s != "hair" && rand(5) != 0
      style_key = styles.keys.sample
      color = styles[style_key].sample
      @clothing[placement] = { garment: style_key, color: color }
    end

    @character_json[:clothing] = @clothing

    set_required_attributes
    remove_invalid_attributes
    set_required_clothing
    # FIXME - Remove all of the above, replace with something like below
    # puts "#{'~'*500} RANDOFY #{'~'*500}".colorize(:red)
    # placements.each do |placement|
    #   if placement.is_a?(Hash)
    #     placement.each do |path, chance|
    #       if rand < chance
    #         randomly_find_clothes_for_path(path)
    #       end
    #     end
    #   elsif placement.is_a?(Array)
    #   else
    #   end
    # end
  end

  def to_components
    components = []
    components << { gender: @gender, placement: "body", garment: @body }

    @character_json[:clothing].each do |placement, details|
      # placement = Symbol (ears, head, shoes, etc)
      # details = { garment: String, color: String }
      cloth = { gender: gender, placement: placement, garment: details[:garment], color: details[:color] }
      components << cloth
    end

    components
  end

  def to_html
    to_components.map { |component| html_for_component(component) }.join("\n").html_safe
  end

  def to_json
    @character_json
  end

  private

  def self.required_placements
    ["body", "torso", "legs", "beard_color", "hair_color"]
  end

  def self.reset_outfits
    @@character_outfits = nil
    @@default_outfits = nil
    default_outfits
  end

  def self.character_outfits
    @@character_outfits ||= begin
      HashWithIndifferentAccess.new(JSON.parse(File.read("lib/assets/valid_character_outfits.rb")))
    end
  end

  def self.outfit_paths_from_list(outfits, list, include_found:)
    (list[:male] ||= {}).deep_merge!(list[:both]) { |key, this_val, other_val| this_val + other_val }
    (list[:female] ||= {}).deep_merge!(list[:both]) { |key, this_val, other_val| this_val + other_val }
    list.except!(:both)

    all_paths = list.all_paths

    if include_found
      found_outfits = {}
      all_paths.each do |*path, item|
        possible_outfits = path.any? ? outfits.dig(*path) : outfits
        possible_outfits.each do |outfit|
          if outfit_includes_item?(outfit, item)
            found_outfits.deep_set(path, item)
          end
        end
      end
      found_outfits
    else
      all_paths.each do |*path, item|
        if path.any?
          outfits.dig(*path).reject! { |outfit| outfit_includes_item?(outfit, item) }
        else
          outfits.reject! { |outfit| outfit_includes_item?(outfit, item) }
        end
      end
      outfits
    end
  end

  def self.outfit_includes_item?(outfit, current_item)
    return true if current_item == "*"

    if outfit.is_a?(Hash)
      current_item.keys.include?(current_item) || current_item.values.include?(current_item)
    else
      outfit.include?(current_item.to_s)
    end
  end

  def self.default_outfits
    @@default_outfits ||= begin
      outfits = character_outfits.dup

      blacklist = {
        both: {
          weapons: [ "*" ],
          arms: [ "gold", "plate" ],
          back: [ "*" ],
          body: [ :orc, :red_orc ],
          torso: [ :plate, :chain, :gold ],
          feet: [ :armor ],
          hands: [ :gloves ],
          head: {
            helms: "*",
            hoods: [ :chain_hood ]
          },
          legs: [ :armor ]
        },
        male: {
          body: [ :skeleton ],
          beard: [ :fiveoclock ],
          eyes: {
            colors: [ :casting_eyeglow_skeleton ]
          }
        },
        female: {
          back: [ :wings ]
        }
      }

      outfit_paths_from_list(outfits, blacklist, include_found: false).clean!
    end
  end

  def default_outfits
    self.class.default_outfits
  end

  def genders
    ["male", "female"]
  end

  def randomly_find_clothes_for_path(path)
    # o = self.class.outfit_paths_from_list(default_outfits, path, include_found: true)
    # binding.pry
    # o
  end

  def remove_invalid_attributes
    @character_json.slice!(:gender, :body, :clothing)
    @character_json[:gender] = nil unless genders.include?(@character_json[:gender])
    @character_json[:body] = nil unless default_outfits[@gender][:body].include?(@character_json[:body])

    new_clothing = {}
    @character_json[:clothing].each do |placement_str, details|
      next unless details.is_a?(Hash)
      placement = placement_str.to_s.to_sym
      details.symbolize_keys!
      if default_outfits.dig(@gender, placement, details[:garment])&.include?(details[:color])
        new_clothing[placement] = { garment: details[:garment], color: details[:color] }
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
      garment = default_outfits[@gender][:torso].keys.sample
      color = default_outfits[@gender][:torso][garment].sample
      { garment: garment, color: color }
    end
    # FIXME: Don't need pants if using a Robe or Dress
    @character_json[:clothing][:legs] ||= begin
      garment = default_outfits[@gender][:legs].keys.sample
      color = default_outfits[@gender][:legs][garment].sample
      { garment: garment, color: color }
    end
    @clothing = @character_json[:clothing]
  end

  def path_for_component(component)
    gender, placement, garment, color = component[:gender], component[:placement], component[:garment], component[:color]
    path = [gender, placement, garment, color].compact.join("/")
    return unless File.exists?("app/assets/images/rpg/#{path}.png")
    ActionController::Base.helpers.asset_path("rpg/#{path}.png")
  end

  # component = { gender: Symbol, placement: Symbol, garment: Symbol, color: Symbol }
  def html_for_component(component)
    gender, placement, garment, color = component[:gender], component[:placement], component[:garment], component[:color]
    url = path_for_component(component)
    return unless url.present?

    "<div class=\"#{placement}\" style=\"background-image: url('#{url}')\"></div>"
  end

  def empty_clothing_obj
    {
      gender: nil,
      body: nil,
      clothing: {
        # back: { garment: "", color: "" },
        # beard: { garment: "", color: "" },
      }
    }
  end

end
