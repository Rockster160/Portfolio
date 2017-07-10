module CharacterBuilderHelper

  def option_builder_json
    outfits = CharacterBuilder.default_outfits
    male = outfits[:male]
    female = outfits[:female]
    {
      male: {
        skin_tone:   male[:body].try(:uniq),
        hair:        male[:hair].try(:keys).try(:uniq),
        hair_color:  male[:hair].try(:values).try(:flatten).try(:uniq),
        beard:       male[:beard].try(:keys).try(:uniq),
        beard_color: male[:beard].try(:values).try(:flatten).try(:uniq),
        eyes:        male[:eyes].try(:values).try(:flatten).try(:uniq),
        ears:        male[:ears].try(:values).try(:flatten).try(:uniq), # Specific to Body
        nose:        male[:nose].try(:values).try(:flatten).try(:uniq), # Specific to Body
        neck:        male[:neck].try(:values).try(:flatten).try(:uniq),
        torso:       male[:torso].try(:values).try(:flatten).try(:uniq),
        head:        male[:head].try(:values).try(:flatten).try(:uniq),
        back:        male[:back].try(:values).try(:flatten).try(:uniq),
        belt:        male[:belt].try(:values).try(:flatten).try(:uniq),
        arms:        male[:arms].try(:values).try(:flatten).try(:uniq),
        hands:       male[:hands].try(:values).try(:flatten).try(:uniq),
        legs:        male[:legs].try(:values).try(:flatten).try(:uniq),
        feet:        male[:feet].try(:values).try(:flatten).try(:uniq)
      },
      female: {
        skin_tone:   female[:body].try(:uniq),
        hair:        female[:hair].try(:keys).try(:uniq),
        hair_color:  female[:hair].try(:values).try(:flatten).try(:uniq),
        beard:       female[:beard].try(:keys).try(:uniq),
        beard_color: female[:beard].try(:values).try(:flatten).try(:uniq),
        eyes:        female[:eyes].try(:values).try(:flatten).try(:uniq),
        ears:        female[:ears].try(:values).try(:flatten).try(:uniq), # Specific to Body
        nose:        female[:nose].try(:values).try(:flatten).try(:uniq), # Specific to Body
        neck:        female[:neck].try(:values).try(:flatten).try(:uniq),
        torso:       female[:torso].try(:values).try(:flatten).try(:uniq),
        head:        female[:head].try(:values).try(:flatten).try(:uniq),
        back:        female[:back].try(:values).try(:flatten).try(:uniq),
        belt:        female[:belt].try(:values).try(:flatten).try(:uniq),
        arms:        female[:arms].try(:values).try(:flatten).try(:uniq),
        hands:       female[:hands].try(:values).try(:flatten).try(:uniq),
        legs:        female[:legs].try(:values).try(:flatten).try(:uniq),
        feet:        female[:feet].try(:values).try(:flatten).try(:uniq)
      }
    }
  end

  def convert_params_hash_to_outfit(params_hash)
    outfits = CharacterBuilder.default_outfits
    gender = params_hash[:gender]
    gender_scope = outfits[gender]
    gender_hash = params_hash[gender]
    other_gender_hash = params_hash[gender.to_sym == :male ? :female : :male]
    other_gender_hash.merge!(gender_hash.reject { |k,v| v.blank? })
    gender_hash = other_gender_hash
    body = gender_hash[:body]

    clothing = {}
    clothing[:hair] = { type: gender_hash[:hair], color: gender_hash[:hair_color] }
    clothing[:beard] = { type: gender_hash[:beard], color: gender_hash[:beard_color] }
    clothing[:ears] = { type: body, color: gender_hash[:ears] }
    clothing[:nose] = { type: body, color: gender_hash[:nose] }

    specified_clothing = [:gender, :body, :hair, :beard, :beard_color, :hair, :hair_color, :ears, :nose]
    non_specific_nested_clothing = gender_hash.except(*specified_clothing)
    non_specific_nested_clothing.each do |garment, color|
      next unless color.present?
      garment_scope = gender_scope[garment]
      matching_garments = garment_scope.select { |type, type_colors| type_colors.include?(color) }
      next unless matching_garments.any?
      type, type_colors = matching_garments.first
      clothing[garment] = { type: type, color: color }
    end

    {
      gender: gender,
      body: body,
      clothing: clothing
    }
  end

end
