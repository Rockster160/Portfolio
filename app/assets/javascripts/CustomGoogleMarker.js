function CustomMarker(latlng, map, args) {
  this.latlng = latlng;
  this.args = args;
  this.setMap(map);
}
customMarkerJs = function() {
  CustomMarker.prototype = new google.maps.OverlayView();
  CustomMarker.prototype.draw = function() {
    var self = this;
    var div = this.div;
    if (!div) {
      div = this.div = document.createElement('div');
      div.className = 'poke-marker';
      var timer = $('<div/>').addClass('poke-timer');
      $(div).append(timer)
      if (typeof(self.args.poke_id) !== 'undefined') {
        var low_res = 'http://pokeapi.co/media/sprites/pokemon/'
        var high_res = 'http://pokeapi.co/media/img/'
        $(div).css({
          'background-image': 'url("' + low_res + self.args.poke_id + '.png")',
          'background-size': 'cover',
          'background-repeat': 'no-repeat',
          'background-position': 'center center'
        })
      }
      google.maps.event.addDomListener(div, 'click', function(event) {
        google.maps.event.trigger(self, 'click');
      });
      google.maps.event.addDomListener(div, 'hover', function(event) {
        google.maps.event.trigger(self, 'hover');
      });
      var panes = this.getPanes();
      panes.overlayImage.appendChild(div);
    }
    var point = this.getProjection().fromLatLngToDivPixel(this.latlng);
    if (point) {
      div.style.left = (point.x - 35) + 'px';
      div.style.top = (point.y - 70) + 'px';
    }
  };
  CustomMarker.prototype.remove = function() {
    if (this.div) {
      this.div.parentNode.removeChild(this.div);
      this.div = null;
    }
  };
  CustomMarker.prototype.getPosition = function() {
    return this.latlng;
  };
}
