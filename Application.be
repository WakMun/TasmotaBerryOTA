import gpio

var strip = Leds(1, gpio.pin(gpio.WS2812, 8))
var colors = [0x00007F, 0x7F0000, 0x007F00]
var index = 0

def change_color()
  strip.clear_to(colors[index])
  strip.show()
  index = (index + 1) % 3
  tasmota.set_timer(2000, change_color, "BlinkTimer")
end

change_color()
