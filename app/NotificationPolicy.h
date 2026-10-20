#ifndef XGLYPH_NOTIFICATION_POLICY_H
#define XGLYPH_NOTIFICATION_POLICY_H
#include <stdbool.h>
#include <stdint.h>

typedef struct { bool low_sent; bool full_sent; } XGNoticeState;
typedef enum { XGNoticeNone, XGNoticeLow, XGNoticeFull, XGNoticeCharging, XGNoticeStopped } XGNotice;

/* A fresh on-battery -> charging edge, never a first/reconnected sample. */
static inline bool xg_charging_started(uint16_t pid, unsigned previous,
        unsigned current, double age, bool previous_known, bool enabled) {
    return enabled && pid == 0xfa65 && previous_known && age >= 0 && age < 30 &&
        previous == 1 && current == 3;
}

static inline bool xg_charging_stopped(uint16_t pid, unsigned previous,
        unsigned current, unsigned percent, double age, bool previous_known, bool enabled) {
    return enabled && pid == 0xfa65 && previous_known && age >= 0 && age < 30 &&
        previous == 3 && current == 1 && percent < 100;
}

/* Only the calibrated wireless readings can produce notifications.
 * Hysteresis prevents a repeat when a reported percentage jitters near a
 * threshold. Delivery flags are committed only after notification submission. */
static inline XGNotice xg_notice(XGNoticeState *history, uint16_t pid,
        unsigned percent, unsigned state, bool fresh, bool wired_present,
        bool low_enabled, bool full_enabled) {
    if (!history || pid != 0xfa65 || !fresh || wired_present || percent > 100)
        return XGNoticeNone;
    if (percent >= 30) history->low_sent = false;
    if (percent <= 95) history->full_sent = false;
    if (low_enabled && state == 1 && percent <= 20 && !history->low_sent)
        return XGNoticeLow;
    /* 100% during the calibrated charging state; this does not assert that
     * charging current has stopped. Unknown state 2 is deliberately excluded. */
    if (full_enabled && state == 3 && percent == 100 && !history->full_sent)
        return XGNoticeFull;
    return XGNoticeNone;
}
#endif
