#ifndef REMOTE_HID_OLED_DISPLAY_H
#define REMOTE_HID_OLED_DISPLAY_H

#include <Arduino.h>
#include <Wire.h>

const uint8_t OLED_DIGITS[] PROGMEM = {
  0x3E, 0x51, 0x49, 0x45, 0x3E,
  0x00, 0x42, 0x7F, 0x40, 0x00,
  0x42, 0x61, 0x51, 0x49, 0x46,
  0x21, 0x41, 0x45, 0x4B, 0x31,
  0x18, 0x14, 0x12, 0x7F, 0x10,
  0x27, 0x45, 0x45, 0x45, 0x39,
  0x3C, 0x4A, 0x49, 0x49, 0x30,
  0x01, 0x71, 0x09, 0x05, 0x03,
  0x36, 0x49, 0x49, 0x49, 0x36,
  0x06, 0x49, 0x49, 0x29, 0x1E
};

const uint8_t OLED_LETTERS[] PROGMEM = {
  0x7E, 0x11, 0x11, 0x11, 0x7E,
  0x7F, 0x49, 0x49, 0x49, 0x36,
  0x3E, 0x41, 0x41, 0x41, 0x22,
  0x7F, 0x41, 0x41, 0x22, 0x1C,
  0x7F, 0x49, 0x49, 0x49, 0x41,
  0x7F, 0x09, 0x09, 0x09, 0x01,
  0x3E, 0x41, 0x49, 0x49, 0x7A,
  0x7F, 0x08, 0x08, 0x08, 0x7F,
  0x00, 0x41, 0x7F, 0x41, 0x00,
  0x20, 0x40, 0x41, 0x3F, 0x01,
  0x7F, 0x08, 0x14, 0x22, 0x41,
  0x7F, 0x40, 0x40, 0x40, 0x40,
  0x7F, 0x02, 0x0C, 0x02, 0x7F,
  0x7F, 0x04, 0x08, 0x10, 0x7F,
  0x3E, 0x41, 0x41, 0x41, 0x3E,
  0x7F, 0x09, 0x09, 0x09, 0x06,
  0x3E, 0x41, 0x51, 0x21, 0x5E,
  0x7F, 0x09, 0x19, 0x29, 0x46,
  0x46, 0x49, 0x49, 0x49, 0x31,
  0x01, 0x01, 0x7F, 0x01, 0x01,
  0x3F, 0x40, 0x40, 0x40, 0x3F,
  0x1F, 0x20, 0x40, 0x20, 0x1F,
  0x3F, 0x40, 0x38, 0x40, 0x3F,
  0x63, 0x14, 0x08, 0x14, 0x63,
  0x07, 0x08, 0x70, 0x08, 0x07,
  0x61, 0x51, 0x49, 0x45, 0x43
};

class OledDisplay {
public:
  OledDisplay()
    : address_(0), linkStatus_(-1), normalState_(0), reconnecting_(false),
      syncError_(false), rttMs_(-1), stateDirty_(false), linkDirty_(false),
      inputDirty_(false), rttDirty_(false), releaseActive_(false),
      releaseUntil_(0), lastRttDisplayAt_(0) {}

  void begin() {
    Wire.begin();
    Wire.setClock(400000);
    address_ = detect(0x3C) ? 0x3C : (detect(0x3D) ? 0x3D : 0);
    if (address_ == 0) {
      return;
    }

    static const uint8_t initialization[] PROGMEM = {
      0xAE, 0xD5, 0x80, 0xA8, 0x1F, 0xD3, 0x00, 0x40,
      0x8D, 0x14, 0x20, 0x00, 0xA1, 0xC8, 0xDA, 0x02,
      0x81, 0x8F, 0xD9, 0xF1, 0xDB, 0x40, 0xA4, 0xA6,
      0x2E, 0xAF
    };
    for (uint8_t i = 0; i < sizeof(initialization); i++) {
      command(pgm_read_byte(&initialization[i]));
    }

    writeLine(0, "REMOTE HID");
    writeLine(1, "HID ACTIVE");
    writeLine(2, "LINK WAIT");
    writeLine(3, "INPUT OK");
  }

  void setState(uint8_t state) {
    if (state == 5) {
      syncError_ = true;
    } else {
      normalState_ = state;
      syncError_ = false;
      stateDirty_ = true;
    }
    inputDirty_ = true;
  }

  void setRtt(unsigned long rttMs) {
    rttMs_ = (long)rttMs;
    rttDirty_ = true;
  }

  void setReconnect(bool reconnecting) {
    if (reconnecting_ != reconnecting) {
      reconnecting_ = reconnecting;
      linkDirty_ = true;
      inputDirty_ = true;
    }
  }

  void showReleaseAll() {
    releaseActive_ = true;
    releaseUntil_ = millis() + 1000;
    inputDirty_ = true;
  }

  void update(bool hasLink, bool linkActive) {
    if (address_ == 0) {
      return;
    }

    uint8_t status = hasLink && !linkActive ? 2 : (reconnecting_ ? 3 : (!hasLink ? 0 : 1));
    if (status != linkStatus_) {
      linkStatus_ = status;
      linkDirty_ = true;
      inputDirty_ = true;
    }
    if (releaseActive_ && (long)(millis() - releaseUntil_) >= 0) {
      releaseActive_ = false;
      inputDirty_ = true;
    }
    if (stateDirty_) {
      stateDirty_ = false;
      writeWindowState();
    }
    if (linkDirty_ || (rttDirty_ && linkStatus_ == 1 && millis() - lastRttDisplayAt_ >= 1000)) {
      linkDirty_ = false;
      rttDirty_ = false;
      lastRttDisplayAt_ = millis();
      writeLinkState();
    }
    if (inputDirty_) {
      inputDirty_ = false;
      writeInputState();
    }
  }

private:
  uint8_t address_;
  int8_t linkStatus_;
  uint8_t normalState_;
  bool reconnecting_;
  bool syncError_;
  long rttMs_;
  bool stateDirty_;
  bool linkDirty_;
  bool inputDirty_;
  bool rttDirty_;
  bool releaseActive_;
  unsigned long releaseUntil_;
  unsigned long lastRttDisplayAt_;

  bool detect(uint8_t address) {
    Wire.beginTransmission(address);
    return Wire.endTransmission() == 0;
  }

  void command(uint8_t value) {
    Wire.beginTransmission(address_);
    Wire.write((uint8_t)0x00);
    Wire.write(value);
    Wire.endTransmission();
  }

  void writeWindowState() {
    switch (normalState_) {
      case 1: writeLine(1, "HID PAUSED"); break;
      case 2: writeLine(1, "L2 ACTIVE"); break;
      case 3: writeLine(1, "WINDOW LOST"); break;
      case 4: writeLine(1, "L2 PAUSED"); break;
      default: writeLine(1, "HID ACTIVE"); break;
    }
  }

  void writeLinkState() {
    if (linkStatus_ == 0) {
      writeLine(2, "LINK WAIT");
      return;
    }
    if (linkStatus_ == 2) {
      writeLine(2, "LINK LOST");
      return;
    }
    if (linkStatus_ == 3) {
      writeLine(2, "RECONNECT");
      return;
    }
    if (rttMs_ < 0) {
      writeLine(2, "LINK --- MS");
      return;
    }
    if (rttMs_ > 999) {
      writeLine(2, "LINK >999MS");
      return;
    }
    char text[17];
    snprintf(text, sizeof(text), "LINK %ld MS", rttMs_);
    writeLine(2, text);
  }

  void writeInputState() {
    if (syncError_) {
      writeLine(3, "SYNC ERROR");
      return;
    }
    if (releaseActive_) {
      writeLine(3, "RELEASE ALL");
      return;
    }
    if (linkStatus_ == 2 || normalState_ == 3) {
      writeLine(3, "INPUT HOLD");
      return;
    }
    if (normalState_ == 1 || normalState_ == 4) {
      writeLine(3, "PAUSED");
      return;
    }
    writeLine(3, "INPUT OK");
  }

  uint8_t glyphColumn(char value, uint8_t column) {
    if (value >= 'a' && value <= 'z') {
      value -= 'a' - 'A';
    }
    if (value >= '0' && value <= '9') {
      return pgm_read_byte(&OLED_DIGITS[(value - '0') * 5 + column]);
    }
    if (value >= 'A' && value <= 'Z') {
      return pgm_read_byte(&OLED_LETTERS[(value - 'A') * 5 + column]);
    }
    if (value == '-') {
      return 0x08;
    }
    if (value == '>') {
      return column == 0 ? 0x41 : (column == 1 ? 0x22 : (column == 2 ? 0x14 : 0x08));
    }
    if (value == '+') {
      return column == 2 ? 0x3E : 0x08;
    }
    if (value == ':') {
      return column == 1 || column == 2 ? 0x36 : 0x00;
    }
    if (value == '_') {
      return 0x40;
    }
    return 0;
  }

  void writeLine(uint8_t row, const char *text) {
    command(0xB0 + row);
    command(0x00);
    command(0x10);

    uint8_t length = strlen(text);
    if (length > 16) {
      length = 16;
    }
    for (uint8_t chunk = 0; chunk < 8; chunk++) {
      uint8_t data[16];
      for (uint8_t i = 0; i < 16; i++) {
        uint8_t position = chunk * 16 + i;
        uint8_t character = position / 8;
        uint8_t column = position % 8;
        data[i] = character < length && column < 5
          ? glyphColumn(text[character], column)
          : 0;
      }
      Wire.beginTransmission(address_);
      Wire.write((uint8_t)0x40);
      Wire.write(data, sizeof(data));
      Wire.endTransmission();
    }
  }
};

#endif
