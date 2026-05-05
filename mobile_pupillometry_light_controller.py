import RPi.GPIO as GPIO
import time

PIN = 17  # GPIO pin for physical pin 11

def run_light():
    GPIO.setmode(GPIO.BCM)

# Active-LOW setup: HIGH = OFF, LOW = ON
    GPIO.setup(PIN, GPIO.OUT, initial=GPIO.HIGH)  # start OFF

    print("💡 Light on  for 10 seconds...")
    time.sleep(10)

    print("💡 Turning light OFF...")
    GPIO.output(PIN, GPIO.HIGH)  # OFF
    time.sleep(.02
)

    print("💡 Forcing GPIO17 back to pull-down mode to keep it OFF")
    GPIO.setup(PIN, GPIO.IN, pull_up_down=GPIO.PUD_DOWN)

    GPIO.cleanup()
    print("✅ Done — pin is now pulled DOWN and LED should stay OFF.")

