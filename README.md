# mobile-pupillometry
# Mobile Pupillometry

Synchronized Raspberry Pi light control system and iPhone system for pupillometry measurements.

## Overview

This system automates pupil response measurements by:
- **Stimulus**: Precise timing control of a light signal via GPIO
- **Trigger**: HID keyboard interface to remotely trigger iPhone camera recording
- **Recording**: Custom iOS app with manual camera controls (exposure, focus, white balance) optimized for pupil imaging
- **Logging**: Event logging on both Pi and iOS sides

## Hardware Requirements

### Raspberry Pi Side
- **Raspberry Pi 4** (tested on 4GB+ RAM)
- **CH9329 UART-to-HID chip** configured as an Apple keyboard (VID: 0x05AC, PID: 0x0220) so iOS recognizes it as a hardware keyboard
- **GPIO 17**: Connected to the light circuit (active-HIGH wiring; GPIO.HIGH = ON)
- **UART connection**: `/dev/ttyS0` at 9600 baud (enable UART in `raspi-config`)
- **Audio output**: For beep playback via `aplay`
- **Foot pedal** (optional): Any USB keyboard-style foot pedal will trigger the sequence

### iPhone Side
- **iPhone** running iOS 15.0 or later
- Camera Connection Kit / USB-C adapter to plug the CH9329 into the iPhone

### Synchronization
- USB cable from CH9329 to iPhone (via Camera Connection Kit / USB-C adapter)

## Software Installation

### Raspberry Pi Setup

1. **Enable UART**:
   ```
   sudo raspi-config
   ```
   Then go to: Interfacing Options → Serial → Enable Serial Port (disable Serial Login)

2. **Install Python dependencies**:
   ```
   sudo apt-get install python3-tk python3-serial python3-pip
   pip3 install pyserial
   ```

3. **Run the controller**:
   ```
   python3 pupilstimulus_gui.py
   ```

### iPhone Setup

1. Open the Xcode project (`Mobile Pupillometry.xcodeproj`)
2. Select your target iPhone in the build scheme
3. Build and run the app (`Cmd+R`)
4. Grant camera and photo library permissions when prompted

## Usage

### Start Recording

1. **iPhone**: Launch the app, adjust camera settings (zoom, exposure, focus) in the drawer panel
2. **Pi**: Launch the controller GUI
3. **Connect**: Plug the CH9329 USB into the iPhone via the Camera Connection Kit
4. **Trigger**: Press the foot pedal (or any key on the Pi, or click "START SEQUENCE") to:
   - Send HID 'A' keypress to iPhone (starts recording)
   - Wait for pre-dark duration
   - Activate light on GPIO 17
   - Wait for light duration
   - Deactivate light
   - Wait for post-illumination duration
   - Play audible beep (marks end of stimulus)

### Timing Parameters (in seconds)
- **Pre-dark**: Baseline period before light activation
- **Light ON**: Duration of light stimulus
- **Post-illumination**: Recovery period after stimulus ends

### iPhone Controls

**Main Recording**:
- **START/STOP**: Manual recording toggle (also triggered by HID 'A' keypress from Pi)
- **Auto-stop**: Enable to automatically stop after a set duration

**Camera Settings**:
- **Zoom**: 1× wide vs 2× telephoto (if available)
- **Macro Mode**: Ultrawide lens for extreme close-ups
- **Manual Exposure**: ISO, shutter speed (ms), white balance (2000–8000 K)
- **Manual Focus**: Lens position (0.0 = nearest, 1.0 = infinity)
- **Advanced**: Video stabilization, lens distortion correction, wide color (P3), exposure bias

**Preview**:
- **Fit**: See full image (may have black bars)
- **Fill**: Crop to screen size
- **Rotation**: 0° / 90° / 180° / 270° to orient the preview and recording

### Data Output

**Raspberry Pi**:
- On-screen status updates showing each stage of the sequence

**iPhone**:
- Recorded video saved to **Photos Library** in 4K HEVC format at 24 fps
- Event log saved to the app's documents folder as `camera_events.csv`
  - Columns: `iso8601, epoch_seconds, event`
  - Events include: `HID_KEY_RECEIVED`, `EXPOSURE_SET`, `SESSION_STARTED`, `SAVED_TO_PHOTOS`, etc.

## Hardware Configuration Details

### CH9329 HID Configuration
The CH9329 chip must be flashed with Apple keyboard identifiers so iOS treats it as a trusted hardware keyboard:
- **VID (Vendor ID)**: 0x05AC (Apple)
- **PID (Product ID)**: 0x0220 (Apple Keyboard)

### GPIO 17 Wiring
- Active-HIGH: `GPIO.HIGH` = light ON
- Use `initial=GPIO.HIGH` in `GPIO.setup()` for reliable activation
- Electrical isolation between the Pi and the light circuit is recommended

### UART Protocol
The Pi sends HID keyboard packets over `/dev/ttyS0` in this format:
```
[0x57, 0xAB, 0x00, 0x02, 0x08, 0x00, 0x00, keycode, 0x00, 0x00, 0x00, 0x00, 0x00, checksum]
```
- **keycode**: 0x04 for 'A' key
- **checksum**: Sum of all preceding bytes modulo 256


## File Structure

```
.
├── mobile_pupillometry_light_controller.py     # Pi controller (Tkinter GUI)
├── mobile_pupillometry.swift                   # iOS app source
├── mobile_pupillometry-Bridging-Header.h       # Objective-C bridge (empty)
├── Info.plist                                  # iOS app configuration
└── Mobile Pupillometry.xcodeproj/              # Xcode project files
```

## Notes

- **Frame rate**: Locked to 24 fps for consistent temporal resolution
- **Codec**: HEVC (H.265) at 4K for efficient storage of long recordings
