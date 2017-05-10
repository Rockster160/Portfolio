monster_hash = {
  '1': {
    'name': 'Monster 1',
    'health': 100,
    'attack': 500,
    'defense': 9038,
    'speed': 7810,
    'crit_rate': 5168,
    'crit_dmg': 5985,
    'accuracy': 6347,
    'resistance': 9769,
    'moves': [
      { 'health': '*2', 'attack': '*0.8' }
    ]
  },
  '2': {
    'name': 'Monster 2',
    'health': 4117,
    'attack': 1732,
    'defense': 750,
    'speed': 8020,
    'crit_rate': 7112,
    'crit_dmg': 8179,
    'accuracy': 1848,
    'resistance': 2600,
    'moves': [
      {  },
      {  },
      {  },
      {  }
    ]
  },
  '3': {
    'name': 'Monster 3',
    'health': 6538,
    'attack': 2918,
    'defense': 9373,
    'speed': 2485,
    'crit_rate': 6937,
    'crit_dmg': 9009,
    'accuracy': 2965,
    'resistance': 4261,
    'moves': [
      {  },
      {  },
      {  },
      {  }
    ]
  },
  '4': {
    'name': 'Monster 4',
    'health': 4339,
    'attack': 7910,
    'defense': 4847,
    'speed': 6044,
    'crit_rate': 9421,
    'crit_dmg': 2299,
    'accuracy': 8881,
    'resistance': 4269,
    'moves': [
      {  },
      {  },
      {  },
      {  }
    ]
  },
  '5': {
    'name': 'Monster 5',
    'health': 4627,
    'attack': 3145,
    'defense': 7199,
    'speed': 2893,
    'crit_rate': 1809,
    'crit_dmg': 9414,
    'accuracy': 8567,
    'resistance': 1084,
    'moves': [
      {  },
      {  },
      {  },
      {  }
    ]
  }
}

$('.ctr-summoners_wars').ready(function() {

  $('input').on('change input keydown', function() {
    updateCalculations();
  })

  currentMonster = function() {
    var monster_id = $('.monster-selector').val();
    return monster_hash[monster_id];
  }

  toNum = function(numStr) {
    var sign = "";
    if (numStr[0] == "-") { sign = "-" }
    return parseInt(sign + "0" + numStr.replace(/[^\d]/g, ""));
  }

  hashToString = function(hash) {
    var str = "";
    $(Object.keys(hash)).each(function() {
      var hKey = this, hVal = hash[hKey];
      str += "</br>" + hKey + ": " + hVal;
    })
    return str;
  }

  calculateAbility = function(abilityJson) {
    var abilityVal = 0;
    $(Object.keys(abilityJson)).each(function(idx) {
      var statName = this,
          statModifierStr = abilityJson[statName],
          statModifier = statModifierStr[0],
          statChange = parseFloat(statModifierStr.substring(1));
      //
      var statValue = getValueFromField($('tr[type=' + statName + '] .computed-total'));
      switch (statModifier) {
        case "+":
          abilityVal += statValue + statChange;
          break;
        case "-":
          abilityVal += statValue - statChange;
          break;
        case "*":
          abilityVal += statValue * statChange;
          break;
        case "/":
          abilityVal += statValue / statChange;
          break;
      }
    })
    return abilityVal;
  }

  $(Object.keys(monster_hash)).each(function() {
    var monster_id = this.toString(), monster_json = monster_hash[monster_id];
    var option = $("<option>", { value: monster_id }).html(monster_json['name']);
    $('.monster-selector').append(option);
  })

  getValueFromField = function(field) {
    var rawFieldVal;
    if ($(field).find("input").length == 0) {
      if ($(field).length == 0) { debugger }
      rawFieldVal = $(field).html().trim();
      if (rawFieldVal.length == 0) { return }
    } else {
      rawFieldVal = $(field).find("input").val().trim();
    }
    return toNum(rawFieldVal);
  }

  displayAbilities = function() {
    var monster_json = currentMonster();
    if (!monster_json) { return };
    var abilities = monster_json["moves"];
    $(abilities).each(function(idx) {
      var abilityVal = calculateAbility(this);
      var abilityRow = '<tr type="ability"><td colspan="2">Ability ' + (idx + 1) + hashToString(this) + '</td><td colspan="2">' + abilityVal + '</td></tr>';
      $('table.monsters').append(abilityRow);
    })
  }

  updateCalculations = function() {
    $('tr').each(function() {
      if ($(this).attr("type") == "ability") {
        $(this).remove();
      } else {
        var attrVal = getValueFromField($(this).find('.attr-value')), runeVal = getValueFromField($(this).find('.rune-value'));
        if (attrVal || runeVal) {
          attrVal = attrVal || 0;
          runeVal = runeVal || 0;
          $(this).find('.computed-total').html(attrVal + runeVal);
        } else {
          $(this).find('.computed-total').html("N/A");
        }
      }
    });
    displayAbilities();
    formatFields();
  }

  formatFields = function() {
    $('.attr-value, .computed-total').each(function() {
      if (!getValueFromField(this)) {
        $(this).html("N/A");
      } else {
        var chars = toNum($(this).html()).toString(), charCount = chars.length, formattedStrParts = [];
        while (chars.length > 3) {
          formattedStrParts.push(chars.substr(-3))
          chars = chars.substring(0, chars.length - 3)
        }
        formattedStrParts.push(chars)
        $(this).html(formattedStrParts.reverse().filter(function(part) { return parseInt(part) > 0 }).join(","));
      }
    })
  }

  updateMonsterAttributes = function() {
    var monster_json = currentMonster();
    $(Object.keys(monster_json)).each(function(a, b, c) {
      var monster_attr_name = this.toString(), monster_attr_val = monster_json[monster_attr_name];
      $('tr[type=' + monster_attr_name + '] td.attr-value').html(monster_attr_val)
    })
    updateCalculations()
  }
  updateCalculations();

  $('.monster-selector').change(function() {
    updateMonsterAttributes($(this).val())
  })


})
