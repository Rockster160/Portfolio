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
        # nose:        male[:nose].try(:values).try(:flatten).try(:uniq), # Specific to Body
        # neck:        male[:neck].try(:values).try(:flatten).try(:uniq),
        torso:       male[:torso].try(:values).try(:flatten).try(:uniq),
        head:        male[:head].try(:values).try(:flatten).try(:uniq),
        # back:        male[:back].try(:values).try(:flatten).try(:uniq),
        arms:        male[:arms].try(:values).try(:flatten).try(:uniq),
        belt:        male[:belt].try(:values).try(:flatten).try(:uniq),
        # hands:       male[:hands].try(:values).try(:flatten).try(:uniq),
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
        # nose:        female[:nose].try(:values).try(:flatten).try(:uniq), # Specific to Body
        # neck:        female[:neck].try(:values).try(:flatten).try(:uniq),
        torso:       female[:torso].try(:values).try(:flatten).try(:uniq),
        head:        female[:head].try(:values).try(:flatten).try(:uniq),
        # back:        female[:back].try(:values).try(:flatten).try(:uniq),
        arms:        female[:arms].try(:values).try(:flatten).try(:uniq),
        belt:        female[:belt].try(:values).try(:flatten).try(:uniq),
        # hands:       female[:hands].try(:values).try(:flatten).try(:uniq),
        legs:        female[:legs].try(:values).try(:flatten).try(:uniq),
        feet:        female[:feet].try(:values).try(:flatten).try(:uniq)
      }
    }
  end

  def outfit_from_top_level_hash(params_hash)
    outfits = CharacterBuilder.default_outfits
    gender = params_hash[:gender]
    gender_scope = outfits[gender] || outfits[:male]
    gender_hash = params_hash[gender] || params_hash[:male]
    body = gender_hash[:body]

    clothing = {}
    clothing[:hair] = { garment: gender_hash[:hair], color: gender_hash[:hair_color] }
    clothing[:beard] = { garment: gender_hash[:beard], color: gender_hash[:beard_color] }
    clothing[:ears] = { garment: body, color: gender_hash[:ears] }
    clothing[:nose] = { garment: body, color: gender_hash[:nose] }

    specified_clothing = [:gender, :body, :hair, :beard, :beard_color, :hair, :hair_color, :ears, :nose]
    non_specific_nested_clothing = gender_hash.except(*specified_clothing)
    non_specific_nested_clothing.each do |garment, color|
      next unless color.present?
      garment_scope = gender_scope[garment]
      matching_garments = garment_scope.select { |garment_cloth, type_colors| type_colors.include?(color) }
      next unless matching_garments.any?
      garment_cloth, type_colors = matching_garments.first
      clothing[garment] = { garment: garment_cloth, color: color }
    end

    {
      gender: gender,
      body: body,
      clothing: clothing
    }
  rescue
    CharacterBuilder.new({}).tap(&:change_random)
  end

end
