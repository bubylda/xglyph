#include "../app/BatteryProtocol.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    BatterySample s = {0};
    const uint8_t full[] = {3, 0x3f, 0x40, 1, 73};
    const uint8_t payload[] = {0x3f, 0x40, 2, 100};
    const uint8_t empty[] = {3, 0x3f, 0x40, 3, 0};
    const uint8_t other[] = {3, 0x3f, 0x50, 1, 73};
    const uint8_t invalid[] = {3, 0x3f, 0x40, 1, 255};
    const uint8_t unknown[] = {3, 0x3f, 0x40, 99, 50};
    const uint8_t embedded[] = {4, 0, 3, 0x3f, 0x40, 1, 73};
    assert(decode_battery(0xfa26, 3, full, sizeof full, &s));
    assert(s.percent == 73 && s.state == 1);
    assert(decode_battery(0xfa73, 3, payload, sizeof payload, &s));
    assert(s.percent == 100 && s.state == 2);
    assert(decode_battery(0xfa26, 3, empty, sizeof empty, &s) && s.percent == 0);
    assert(!decode_battery(0xfa26, 4, full, sizeof full, &s));
    assert(!decode_battery(0xfa26, 3, full, 3, &s));
    assert(!decode_battery(0xfa26, 3, other, sizeof other, &s));
    assert(!decode_battery(0xfa26, 3, invalid, sizeof invalid, &s));
    assert(!decode_battery(0xfa26, 4, embedded, sizeof embedded, &s));
    assert(decode_battery(0xfa26, 3, unknown, sizeof unknown, &s) && s.state == 99);
    assert(!decode_battery(0xfa26, 3, NULL, 0, &s));
    assert(!decode_battery(0xfa26, 3, full, sizeof full, NULL));
    const uint8_t actual_battery[] = {3, 0x30, 0x40, 1, 0x44};
    const uint8_t actual_charging[] = {3, 0x30, 0x40, 3, 0x44};
    const uint8_t actual_wired[] = {3, 0x30, 0x40, 3, 0x64};
    assert(decode_battery(0xfa65, 3, actual_battery, 5, &s));
    assert(s.percent == 68 && s.state == 1);
    assert(decode_battery(0xfa65, 3, actual_charging, 5, &s));
    assert(s.percent == 68 && s.state == 3);
    assert(decode_battery(0xfa65, 3, actual_charging + 1, 4, &s));
    assert(!decode_battery(0xfa26, 3, actual_battery, 5, &s));
    assert(!decode_battery(0xfa65, 3, full, 5, &s));
    assert(!decode_battery(0x1234, 3, full, 5, &s));
    assert(decode_battery(0xfa73, 3, actual_wired, 5, &s));
    assert(s.percent == 100 && s.state == 3);
    assert(decode_battery(0xfa73, 3, actual_wired + 1, 4, &s));
    puts("Protocol tests passed.");
    return 0;
}
