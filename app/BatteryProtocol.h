#ifndef XGLYPH_BATTERY_PROTOCOL_H
#define XGLYPH_BATTERY_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t percent;
    uint8_t state;
} BatterySample;

/* FA65 receiver and installed FA73 firmware: 30 40 observed on hardware.
 * The supplied updater targets FA26/FA73 with a firmware using 3F 40.
 * Report 04 is a different vendor protocol. */
static inline bool decode_battery(uint16_t product_id, uint32_t report_id, const uint8_t *bytes,
                                  size_t count, BatterySample *sample) {
    if (report_id != 3 || !bytes || !sample) return false;
    if (product_id != 0xfa65 && product_id != 0xfa26 && product_id != 0xfa73)
        return false;
    if (count == 5 && bytes[0] == 3) {
        ++bytes;
        --count;
    }
    if (count != 4) return false;
    bool prefix_ok = product_id == 0xfa65 ? bytes[0] == 0x30 :
                     product_id == 0xfa26 ? bytes[0] == 0x3f :
                     (bytes[0] == 0x30 || bytes[0] == 0x3f);
    if (!prefix_ok || bytes[1] != 0x40 ||
        bytes[3] > 100) return false;
    sample->state = bytes[2];
    sample->percent = bytes[3];
    return true;
}

#endif
