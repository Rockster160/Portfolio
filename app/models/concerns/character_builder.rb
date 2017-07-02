# CharacterBuilder.all_clothing_paths
class CharacterBuilder
  attr_accessor :character_json

  def initialize
    @character_json = empty_clothing_obj
  end

  # def FIXME self.html_for_character_obj(character)
  #   gender = character[:gender]
  #   body_type = character[:body]
  #   body = html_for_cloth_path(gender: gender, placement: "body", type: body_type)
  #   character_html = [body]
  #
  #   character[:clothing].each do |placement, details|
  #     # placement: { type: "", color: "" }
  #     cloth = { gender: gender, placement: placement, type: details[:type], color: details[:color] }
  #     character_html << html_for_cloth_path(cloth)
  #   end
  #
  #   character_html.join("\n").html_safe
  # end

  # def FIXME self.build_character_from_clothing_params(clothing_params)
  #   character = empty_clothing_obj
  #
  #   [clothing_params || []].each do |cloth|
  #     next unless cloth
  #     cloth_obj = extract_obj_from_cloth_array_str(cloth)
  #     next unless cloth_obj
  #     character[:gender] ||= cloth_obj[:gender]
  #     if cloth_obj[:placement].to_s.to_sym == :body
  #       character[:body] ||= cloth_obj[:type]
  #     else
  #       placement = cloth_obj[:placement].to_s.to_sym
  #       character[:clothing][placement] ||= {}
  #       character[:clothing][placement][:type] ||= cloth_obj[:type].to_s
  #       character[:clothing][placement][:color] ||= cloth_obj[:color].to_s
  #     end
  #   end
  #
  #   character = autofill_required_attributes(character)
  #
  #   character
  # end

  # def FIXME self.html_for_cloth_path(cloth_obj)
  #   gender, placement, type, color = cloth_obj[:gender], cloth_obj[:placement], cloth_obj[:type], cloth_obj[:color]
  #   path = [gender, placement, type, color].compact.join("/")
  #   return unless File.exists?("app/assets/images/rpg/#{path}.png")
  #   url = ActionController::Base.helpers.asset_path("rpg/#{path}.png")
  #
  #   "<div class=\"#{placement}\" style=\"background-image: url('#{url}')\"></div>".html_safe
  # end

  # def FIXME self.generate_random_character
  #   character = empty_clothing_obj
  #   gender = character[:gender] = [:male, :female].sample
  #   body = character[:body] = character_outfits[gender][:body].sample
  #
  #   character_outfits[gender].keys.each do |placement|
  #     next if placement == :body
  #     next if placement == :weapons
  #     next if !required_placements.include?(placement) && rand(2) == 0
  #
  #     character[:clothing][placement] ||= {}
  #     character[:clothing][placement][:type] ||= character_outfits[gender][placement].keys.sample
  #     type = character[:clothing][placement][:type]
  #     character[:clothing][placement][:color] ||= character_outfits[gender][placement][type].sample
  #   end
  #
  #   character
  # end

  # def FIXME self.all_clothing_paths
  #   clothing = paths_for_hash(character_outfits)
  #   clothing.map do |path|
  #     gender, placement, type, color = path.split("/")
  #     { gender: gender, placement: placement, type: type, color: color }
  #   end
  # end

  # def FIXME self.paths_for_hash(hash)
  #   paths = []
  #   hash.map do |key, vals|
  #     if vals.is_a?(Hash)
  #       paths_for_hash(vals).each do |path|
  #         paths << [key, path].join("/")
  #       end
  #     else
  #       vals.each do |val|
  #         paths << [key, val].join("/")
  #       end
  #     end
  #   end
  #   paths
  # end

  # def FIXME self.character_outfits
  #   @@character_outfits ||= begin
  #     JSON.parse(File.read("lib/assets/valid_character_outfits.rb")).deep_symbolize_keys
  #   end
  # end

  private

  # def FIXME self.required_placements
  #   [:body, :torso, :legs]
  # end

  # def FIXME self.image_types
  #   [:accessories, :behind_body, :belt, :body, :facial, :feet, :formal, :hair, :hands, :head, :legs, :torso, :weapons]
  # end

  # def FIXME empty_clothing_obj
  #   {
  #     gender: nil,
  #     body: nil,
  #     clothing: {
  #       # back: { type: "", color: "" },
  #       # beard: { type: "", color: "" },
  #     }
  #   }
  # end

  # def FIXME self.autofill_required_attributes(character)
  #   gender = character[:gender] ||= [:male, :female].sample
  #
  #   body = character[:body] ||= character_outfits[gender][:body].sample
  #
  #   torso = character[:clothing][:torso] ||= {}
  #   torso_type = character[:clothing][:torso][:type] ||= character_outfits[gender][:torso].keys.sample
  #   torso_color = character[:clothing][:torso][:color] ||= character_outfits[gender][:torso][torso_type].sample
  #
  #   legs = character[:clothing][:legs] ||= {}
  #   legs_type = character[:clothing][:legs][:type] ||= character_outfits[gender][:legs].keys.sample
  #   legs_color = character[:clothing][:legs][:color] ||= character_outfits[gender][:legs][legs_type].sample
  #
  #   character
  # end

  # def FIXME self.extract_obj_from_cloth_array_str(cloth)
  #   return unless cloth.is_a?(String)
  #   gender, placement, type, color = cloth[1..-2].split(",").map {|str| str.gsub(":", "").squish }
  #   { gender: gender, placement: placement, type: type, color: color }
  # end

end
# CharacterBuilder.generate_random_character
