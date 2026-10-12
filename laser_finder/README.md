## Laser Line Bit Finder

This program uses
- Freenove esp32-WROOM-32E
- 2 phototransistors
- 3 LEDs
- 50mW line laser (650 nm)

- display [ for development ]


to sense the position of a reflective object (an endmill bit) relative to the laser line.  The expectation is that the centered bit will relect back to the two phototransistors equally when centered.

- ADC Channel 4 is associated with pin 4
- ADC Channel 5 is associated with pin 5<br><br>
- Left LED is PWM controlled via pin 17
- Center LED is PWM controlled via pin 18
- Right LED is PWM controlledf via pin 19


