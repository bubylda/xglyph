#include "../app/NotificationPolicy.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    assert(xg_charging_started(0xfa65,1,3,1,true,true));
    assert(!xg_charging_started(0xfa65,3,3,1,true,true));
    assert(!xg_charging_started(0xfa65,1,3,0,false,true));
    assert(!xg_charging_started(0xfa65,1,3,30,true,true));
    assert(!xg_charging_started(0xfa65,1,3,-1,true,true));
    assert(!xg_charging_started(0xfa65,2,3,1,true,true));
    assert(!xg_charging_started(0xfa65,3,1,1,true,true));
    assert(!xg_charging_started(0xfa65,1,3,1,true,false));
    assert(!xg_charging_started(0xfa73,1,3,1,true,true));
    assert(xg_charging_stopped(0xfa65,3,1,82,1,true,true));
    assert(xg_charging_stopped(0xfa65,3,1,99,1,true,true));
    assert(xg_charging_stopped(0xfa65,3,1,0,1,true,true));
    assert(!xg_charging_stopped(0xfa65,3,1,100,1,true,true));
    assert(!xg_charging_stopped(0xfa65,3,1,255,1,true,true));
    assert(!xg_charging_stopped(0xfa65,1,1,82,1,true,true));
    assert(!xg_charging_stopped(0xfa65,3,2,82,1,true,true));
    assert(!xg_charging_stopped(0xfa65,2,1,82,1,true,true));
    assert(!xg_charging_stopped(0xfa65,3,1,82,0,false,true));
    assert(!xg_charging_stopped(0xfa65,3,1,82,30,true,true));
    assert(!xg_charging_stopped(0xfa65,3,1,82,-1,true,true));
    assert(!xg_charging_stopped(0xfa65,3,1,82,1,true,false));
    assert(!xg_charging_stopped(0xfa73,3,1,82,1,true,true));
    XGNoticeState s = {0};
    assert(xg_notice(&s,0xfa65,20,1,true,false,true,true)==XGNoticeLow);
    s.low_sent=true;
    assert(xg_notice(&s,0xfa65,19,1,true,false,true,true)==XGNoticeNone);
    assert(xg_notice(&s,0xfa65,21,1,true,false,true,true)==XGNoticeNone);
    assert(s.low_sent);
    assert(xg_notice(&s,0xfa65,30,3,true,false,true,true)==XGNoticeNone);
    assert(!s.low_sent);
    assert(xg_notice(&s,0xfa65,0,1,true,false,true,true)==XGNoticeLow);
    assert(xg_notice(&s,0xfa65,10,3,true,false,true,true)==XGNoticeNone);
    assert(xg_notice(&s,0xfa65,100,3,true,false,true,true)==XGNoticeFull);
    s.full_sent=true;
    assert(xg_notice(&s,0xfa65,100,3,true,false,true,true)==XGNoticeNone);
    assert(xg_notice(&s,0xfa65,99,3,true,false,true,true)==XGNoticeNone);
    assert(s.full_sent);
    assert(xg_notice(&s,0xfa65,95,1,true,false,true,true)==XGNoticeNone);
    assert(!s.full_sent);
    assert(xg_notice(&s,0xfa65,100,2,true,false,true,true)==XGNoticeNone);
    assert(xg_notice(&s,0xfa65,100,1,true,false,true,true)==XGNoticeNone);
    assert(xg_notice(&s,0xfa73,100,3,true,false,true,true)==XGNoticeNone);
    assert(xg_notice(&s,0xfa65,20,1,false,false,true,true)==XGNoticeNone);
    assert(xg_notice(&s,0xfa65,20,1,true,true,true,true)==XGNoticeNone);
    assert(xg_notice(&s,0xfa65,20,1,true,false,false,true)==XGNoticeNone);
    assert(xg_notice(&s,0xfa65,100,3,true,false,true,false)==XGNoticeNone);
    assert(xg_notice(&s,0xfa65,255,1,true,false,true,true)==XGNoticeNone);
    puts("Notification policy tests passed.");
    return 0;
}
