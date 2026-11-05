#include <HID.h>
#include "OledDisplay.h"

const unsigned long LINK_TIMEOUT_MS = 2000;
const uint8_t COMMAND_BUFFER_SIZE = 24;
const uint8_t MOUSE_REPORT_ID = 1;
const uint8_t KEYBOARD_REPORT_ID = 2;

const uint8_t keyboardDescriptorData[] PROGMEM = {
  0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
  0x85, 0x02, 0x05, 0x07, 0x19, 0xE0,
  0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
  0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
  0x95, 0x01, 0x75, 0x08, 0x81, 0x03,
  0x95, 0x06, 0x75, 0x08, 0x15, 0x00,
  0x25, 0x65, 0x05, 0x07, 0x19, 0x00,
  0x29, 0x65, 0x81, 0x00, 0xC0
};

const uint8_t mouseDescriptorData[] PROGMEM = {
  0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
  0x85, 0x01, 0x09, 0x01, 0xA1, 0x00,
  0x05, 0x09, 0x19, 0x01, 0x29, 0x03,
  0x15, 0x00, 0x25, 0x01, 0x95, 0x03,
  0x75, 0x01, 0x81, 0x02, 0x95, 0x01,
  0x75, 0x05, 0x81, 0x03, 0x05, 0x01,
  0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
  0x15, 0x81, 0x25, 0x7F, 0x75, 0x08,
  0x95, 0x03, 0x81, 0x06, 0xC0, 0xC0
};

struct KeyboardReport {
  uint8_t modifiers;
  uint8_t reserved;
  uint8_t keys[6];
};

struct MouseReport {
  uint8_t buttons;
  int8_t x;
  int8_t y;
  int8_t wheel;
};

KeyboardReport keyboardReport;
MouseReport mouseReport;
HIDSubDescriptor keyboardDescriptor(keyboardDescriptorData, sizeof(keyboardDescriptorData));
HIDSubDescriptor mouseDescriptor(mouseDescriptorData, sizeof(mouseDescriptorData));

class HidDescriptorRegistration {
public:
  HidDescriptorRegistration() {
    HID().AppendDescriptor(&keyboardDescriptor);
    HID().AppendDescriptor(&mouseDescriptor);
  }
};

HidDescriptorRegistration hidDescriptorRegistration;
OledDisplay display;
char commandBuffer[COMMAND_BUFFER_SIZE];
uint8_t commandLength = 0;
unsigned long lastCommandAt = 0;
bool hasLink = false;
bool keysMayBePressed = false;
bool mouseButtonsMayBePressed = false;

void sendKeyboardReport() {
  HID().SendReport(KEYBOARD_REPORT_ID, &keyboardReport, sizeof(keyboardReport));
}

void sendMouseReport() {
  HID().SendReport(MOUSE_REPORT_ID, &mouseReport, sizeof(mouseReport));
}

uint8_t toHidCode(uint8_t code) {
  if (code >= 'a' && code <= 'z') {
    return 0x04 + code - 'a';
  }
  if (code >= '1' && code <= '9') {
    return 0x1E + code - '1';
  }
  if (code == '0') {
    return 0x27;
  }
  if (code == ' ') {
    return 0x2C;
  }
  if (code >= 0xC1 && code <= 0xCC) {
    return 0x3A + code - 0xC1;
  }

  switch (code) {
    case 0xB0: return 0x28;
    case 0xB1: return 0x29;
    case 0xB3: return 0x2B;
    case 0xD7: return 0x4F;
    case 0xD8: return 0x50;
    case 0xD9: return 0x51;
    case 0xDA: return 0x52;
    default: return 0;
  }
}

void pressKey(uint8_t code) {
  if (code >= 0x80 && code <= 0x87) {
    keyboardReport.modifiers |= 1 << (code - 0x80);
    sendKeyboardReport();
    return;
  }

  uint8_t hidCode = toHidCode(code);
  if (hidCode == 0) {
    return;
  }

  for (uint8_t i = 0; i < 6; i++) {
    if (keyboardReport.keys[i] == hidCode) {
      return;
    }
  }

  for (uint8_t i = 0; i < 6; i++) {
    if (keyboardReport.keys[i] == 0) {
      keyboardReport.keys[i] = hidCode;
      sendKeyboardReport();
      return;
    }
  }
}

void releaseKey(uint8_t code) {
  if (code >= 0x80 && code <= 0x87) {
    keyboardReport.modifiers &= ~(1 << (code - 0x80));
    sendKeyboardReport();
    return;
  }

  uint8_t hidCode = toHidCode(code);
  for (uint8_t i = 0; i < 6; i++) {
    if (keyboardReport.keys[i] == hidCode) {
      keyboardReport.keys[i] = 0;
      sendKeyboardReport();
      return;
    }
  }
}

int8_t limitedDelta(int value) {
  if (value > 127) {
    return 127;
  }
  if (value < -127) {
    return -127;
  }
  return (int8_t)value;
}

void moveMouse(int x, int y) {
  while (x != 0 || y != 0) {
    int8_t dx = limitedDelta(x);
    int8_t dy = limitedDelta(y);
    mouseReport.x = dx;
    mouseReport.y = dy;
    mouseReport.wheel = 0;
    sendMouseReport();
    x -= dx;
    y -= dy;
  }
  mouseReport.x = 0;
  mouseReport.y = 0;
}

void setMouseButton(uint8_t button, bool pressed) {
  if (button < 1 || button > 3) {
    return;
  }

  uint8_t mask = 1 << (button - 1);
  if (pressed) {
    mouseReport.buttons |= mask;
    mouseButtonsMayBePressed = true;
  } else {
    mouseReport.buttons &= ~mask;
  }
  mouseReport.x = 0;
  mouseReport.y = 0;
  mouseReport.wheel = 0;
  sendMouseReport();
}

void scrollMouse(int ticks) {
  while (ticks != 0) {
    int8_t delta = limitedDelta(ticks);
    mouseReport.x = 0;
    mouseReport.y = 0;
    mouseReport.wheel = delta;
    sendMouseReport();
    ticks -= delta;
  }
  mouseReport.wheel = 0;
}

void releaseControls() {
  memset(&keyboardReport, 0, sizeof(keyboardReport));
  memset(&mouseReport, 0, sizeof(mouseReport));

  if (keysMayBePressed) {
    sendKeyboardReport();
  }
  if (mouseButtonsMayBePressed) {
    sendMouseReport();
  }

  keysMayBePressed = false;
  mouseButtonsMayBePressed = false;
  display.setActivity("RELEASE ALL");
}

bool parseLong(const char *text, long *value, char **end) {
  *value = strtol(text, end, 10);
  return *end != text;
}

void handleCommand(const char *command) {
  if (strcmp(command, "H") == 0) {
    hasLink = true;
    lastCommandAt = millis();
    return;
  }

  if (strcmp(command, "R") == 0) {
    releaseControls();
    hasLink = true;
    lastCommandAt = millis();
    return;
  }

  char *end;
  long first;
  long second;

  if (command[0] == 'M' && command[1] == ' ') {
    if (!parseLong(command + 2, &first, &end) || *end != ' ') {
      return;
    }
    if (!parseLong(end + 1, &second, &end) || *end != '\0') {
      return;
    }
    if (first < -32768 || first > 32767 || second < -32768 || second > 32767) {
      return;
    }
    moveMouse((int)first, (int)second);
  } else if (command[0] == 'V' && command[1] == ' ') {
    if (!parseLong(command + 2, &first, &end) || *end != '\0' || first < -127 || first > 127) {
      return;
    }
    scrollMouse((int)first);
  } else if (command[0] == 'B' && command[1] == ' ') {
    if (!parseLong(command + 2, &first, &end) || *end != ' ') {
      return;
    }
    if (!parseLong(end + 1, &second, &end) || *end != '\0') {
      return;
    }
    if (first < 1 || first > 3 || (second != 0 && second != 1)) {
      return;
    }
    setMouseButton((uint8_t)first, second == 1);
  } else if ((command[0] == 'D' || command[0] == 'U') && command[1] == ' ') {
    if (!parseLong(command + 2, &first, &end) || *end != '\0' || first <= 0 || first > 255) {
      return;
    }
    if (command[0] == 'D') {
      pressKey((uint8_t)first);
      keysMayBePressed = true;
    } else {
      releaseKey((uint8_t)first);
    }
  } else {
    return;
  }

  if (command[0] == 'D') {
    display.setActivity("KEY DOWN");
  } else if (command[0] == 'U') {
    display.setActivity("KEY UP");
  } else if (command[0] == 'B') {
    display.setActivity("MOUSE BUTTON");
  } else if (command[0] == 'V') {
    display.setActivity("WHEEL");
  } else if (command[0] == 'M') {
    display.setActivity("MOUSE MOVE");
  }

  hasLink = true;
  lastCommandAt = millis();
}

void setup() {
  Serial.begin(115200);
  display.begin();
  lastCommandAt = millis();
}

void loop() {
  while (Serial.available() > 0) {
    char incoming = (char)Serial.read();

    if (incoming == '\r' || incoming == '\n') {
      if (commandLength > 0) {
        commandBuffer[commandLength] = '\0';
        handleCommand(commandBuffer);
        commandLength = 0;
      }
    } else if (incoming >= 32 && incoming <= 126) {
      if (commandLength < COMMAND_BUFFER_SIZE - 1) {
        commandBuffer[commandLength++] = incoming;
      } else {
        commandLength = 0;
      }
    }
  }

  bool linkActive = hasLink && millis() - lastCommandAt <= LINK_TIMEOUT_MS;
  if ((keysMayBePressed || mouseButtonsMayBePressed) && hasLink && !linkActive) {
    releaseControls();
  }
  display.update(hasLink, linkActive);
}
