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

end
