import { Parser } from "../support/parser.js"

var currentMonster;
$(document).ready(function() {
  if ($(".ctr-summoners_wars").length == 0) { return }

  $('.monster-selector').searchableFromSelect({
    retainFieldValueAfterSelect: true,
    templateFromOption: function(monster) {
      return '<div class="monster-option">' +
        '<img class="monster-thumb" src="' + monster.thumb + '" alt="' + monster.name + '">' +
        monster.stars + '<i class="fa fa-star"></i>' +
        '<img src="https://swarfarm.com/static/herders/images/elements/' + monster.element + '.png" alt="' + monster.element + '">' +
        monster.text + ' [' + monster.archetype + ']' +
        '</div>';
    }
  })

  $('input').on('change input keydown', function() {
    updateCalculations();
  })

  $('.monster-selector').change(function() {
    setCurrentMonster();
  })

  setCurrentMonster = function() {
    currentMonster = undefined;
    var monster_id = $('.monster-selector').val();
    if (!monster_id) { return updateMonsterAttributes(); }
    var url = $('.monster-selector').attr("data-monster-details") + "/" + monster_id;
    $.get(url).done(function(data) {
      currentMonster = data;
      updateMonsterAttributes();
    })
  }

  updateMonsterAttributes = function() {
    if (currentMonster) {
      $(Object.keys(currentMonster)).each(function() {
        var monster_attr_name = this.toString(), monster_attr_val = currentMonster[monster_attr_name];
        $('tr[data-long-type=' + monster_attr_name + '] td.attr-value').html(monster_attr_val)
      })
    } else {
      $('tr[type] td.attr-value').html("N/A");
    }
    updateCalculations()
  }

  updateCalculations = function() {
    $('tr[type!=SKILL]').each(function() {
      var attrVal = getValueFromField($(this).find('.attr-value')), runeVal = getValueFromField($(this).find('.rune-value'));
      if (attrVal || runeVal) {
        attrVal = attrVal || 0;
        runeVal = runeVal || 0;
        $(this).find('.computed-total').html(attrVal + runeVal);
      } else {
        $(this).find('.computed-total').html("N/A");
      }
    });
    updateSkills();
    formatFields();
  }

  updateSkills = function() {
    $('tr[type=SKILL]').remove();
    if (!currentMonster) { return };
    var skills = currentMonster["monster_skills"];
    $(skills).each(function(idx) {
      var skillRow = $("<tr>", {type: "SKILL"}),
          skillNameCol = $("<td>").html('<p>' + this['name'] + '</p><p class="normal">' + this["muliplier_formula"] + '</p>'),
          skillDescCol = $("<td>", {colspan: "2"}).html("<p>" + this["description"] + "</p>"),
          skillVal = calculateSkill(this, skillNameCol)
          skillValCol = $("<td>").html(skillVal);
      if (!skillVal.match(/[^\d,\.( x\d+$)]/)) {
        skillValCol.append('<span class="crit">Crit: ' + calculateCrit(skillVal) + '</span>')
      }
      $('table.monsters').append(skillRow.append(skillNameCol, skillDescCol, skillValCol));
    })
  }

  formatFields = function() {
    $('.attr-value, .computed-total').each(function() {
      var fieldVal = getValueFromField(this);
      if (!(fieldVal == 0 || fieldVal)) {
        $(this).html("N/A");
      } else {
        if ([ "CRI_RATE", "CRI_DMG", "RES", "ACC" ].includes($(this).parent().attr("type"))) {
          $(this).html(formatNum(fieldVal) + "%");
        } else {
          $(this).html(formatNum(fieldVal));
        }
      }
    })
  }

  formatNum = function(num) {
    var splitByDecimal = num.toString().split(".");
    var chars = splitByDecimal[0], decimals = splitByDecimal[1], charCount = chars.length, formattedStrParts = [];
    while (chars.length > 3) {
      formattedStrParts.push(chars.substr(-3))
      chars = chars.substring(0, chars.length - 3)
    }
    formattedStrParts.push(chars)
    var withCommas = formattedStrParts.reverse().filter(function(part) { return parseInt(part) > 0 || part == "0" }).join(",")
    if (decimals) { withCommas = withCommas + "." + decimals };

    return withCommas;
  }

  formatStringOfNums = function(str) {
    $(str.match(/\d+(\.\d+)?/g)).each(function() {
      var isNum = !Number.isNaN(parseFloat(this));
      if (isNum) {
        var rounded = round(this);
        str = str.replace(this, formatNum(rounded))
      }
    })
    return str
  }

  monsterStats = function() {
    var stats = {};
    $('tr[type!=SKILL]').each(function() {
      stats[$(this).attr("type")] = getValueFromField($(this).find('.computed-total'));
    })
    return stats;
  }

  calculateSkill = function(skillJson, skillNameCol) {
    var skill = skillJson.muliplier_formula || "",
        hitsCount = $(skill.match(/x\d+$/))[0],
        multipliers = [];
    if (!skill) { return "N/A" }
    $(skill.match(/(HP|ATK|DEF|SPD|CRI_Rate|CRI_DMG|RES|ACC)/ig)).each(function() {
      skill = skill.replace("\b" + this, getValueFromField($('tr[type=' + this + '] .computed-total')));
    })

    var expr = Parser.parse(skill.replace(/ x\d+$/, "").replace(/(\w) (\w)/g, "$1_$2"));
    // toString twice because toString on the expression returns a number if the
    //   the evaluation completes
    var simplified = expr.simplify(monsterStats()).toString().toString();
    var formatted = formatStringOfNums(simplified);
    if (hitsCount) { formatted = formatted + " " + hitsCount };

    return formatted;
  }

  calculateCrit = function(skillValStr) {
    var skillDMG = parseFloat(skillValStr.replace(/[^\d\.]/g, "")), critMult = getValueFromField($('tr[type=CRI_DMG] .computed-total'));
    return formatNum(round(skillDMG + (skillDMG * (critMult / 100))));
  }

  round = function(num) {
    return Math.round(num * 100) / 100;
  }

  parseNum = function(numStr) {
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

  getValueFromField = function(field) {
    if ($(field).length == 0) { return }
    var rawFieldVal;
    if ($(field).find("input").length == 0) {
      rawFieldVal = $(field).html().trim();
      if (rawFieldVal.length == 0) { return }
    } else {
      rawFieldVal = $(field).find("input").val().trim();
    }
    return parseNum(rawFieldVal);
  }

  updateCalculations();
})
