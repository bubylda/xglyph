#import <Cocoa/Cocoa.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <UserNotifications/UserNotifications.h>
#import <ServiceManagement/ServiceManagement.h>
#import "NotificationPolicy.h"
#import "BatteryProtocol.h"

#define L(key) NSLocalizedString(key, nil)

static const NSTimeInterval Freshness = 30;
static BOOL diagnostics = NO;
static BOOL notificationSmoke = NO;

static BOOL isLoginLaunch(NSAppleEventDescriptor *event) {
    if (event.eventClass != kCoreEventClass || event.eventID != kAEOpenApplication) return NO;
    OSType reason = [event paramDescriptorForKeyword:keyAEPropData].enumCodeValue;
    return reason == keyAELaunchedAsLogInItem || reason == keyAELaunchedAsServiceItem;
}

@interface XGDevice : NSObject {
@public
    IOHIDDeviceRef handle;
    uint8_t buffer[1024];
}
@property uint16_t pid;
@property uint64_t identifier;
@property NSString *notificationKey;
@property BOOL opened;
@property IOReturn error;
@property NSDate *received;
@property unsigned percent;
@property unsigned state;
@property BOOL chargingStarted;
@property BOOL chargingStopped;
@property(copy) void (^changed)(void);
@end

static void report(void *context, IOReturn result, void *sender,
                   IOHIDReportType type, uint32_t reportID, uint8_t *bytes, CFIndex length) {
    (void)sender;
    XGDevice *device = (__bridge XGDevice *)context;
    if (result != kIOReturnSuccess || type != kIOHIDReportTypeInput || length < 0) return;
    BatterySample sample;
    if (!decode_battery(device.pid, reportID, bytes, (size_t)length, &sample)) return;
    NSDate *now = NSDate.date;
    device.chargingStarted = xg_charging_started(device.pid, device.state, sample.state,
        device.received ? [now timeIntervalSinceDate:device.received] : 0, device.received != nil, true);
    device.chargingStopped = xg_charging_stopped(device.pid, device.state, sample.state, sample.percent,
        device.received ? [now timeIntervalSinceDate:device.received] : 0, device.received != nil, true);
    device.received = now;
    device.percent = sample.percent;
    device.state = sample.state;
    if (diagnostics) printf("sample pid=%04X percent=%u state=%u\n", device.pid, device.percent, device.state);
    if (device.changed) device.changed();
}

@implementation XGDevice
- (void)dealloc {
    if (self.opened && handle) {
        IOHIDDeviceRegisterInputReportCallback(handle, buffer, sizeof buffer, NULL, NULL);
        IOHIDDeviceUnscheduleFromRunLoop(handle, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        IOHIDDeviceClose(handle, kIOHIDOptionsTypeNone);
    }
    if (handle) CFRelease(handle);
}
@end

@interface XGPresentation : NSObject
@property NSString *value;
@property NSString *detail;
@property NSString *connection;
@property NSString *symbol;
@property NSString *updated;
@property NSString *hint;
@property NSNumber *percent;
@end
@implementation XGPresentation
@end

/* A wired connection takes precedence over a recent receiver packet. Never
 * display the wired firmware's unverified 100% as a measured battery level. */
static XGPresentation *present(NSArray<XGDevice *> *devices, NSDate *now) {
    XGPresentation *p = [XGPresentation new];
    p.value = @"—"; p.detail = L(@"Mouse unavailable"); p.connection = L(@"No receiver connected");
    p.symbol = @"battery.0percent"; p.updated = L(@"No battery report yet");
    p.hint = L(@"Connect your M900 Pro receiver to begin.");
    XGDevice *selected = nil;
    for (XGDevice *d in devices) {
        if (d.pid == 0xfa73 || d.pid == 0xfa26) { selected = d; break; }
        if (!selected || (d.received && (!selected.received || [d.received compare:selected.received] == NSOrderedDescending))) selected = d;
    }
    if (!selected) return p;
    p.connection = selected.pid == 0xfa65 ? L(@"2.4 GHz receiver") : L(@"Wired USB");
    if (!selected.opened) {
        p.detail = L(@"Unable to read mouse");
        p.hint = selected.error == kIOReturnNotPermitted
            ? L(@"Allow XGlyph in Privacy & Security → Input Monitoring, then reopen it.")
            : L(@"Reconnect the receiver, or use Check Connection.");
        return p;
    }
    if (selected.received) {
        NSTimeInterval age = MAX(0, [now timeIntervalSinceDate:selected.received]);
        p.updated = age < 5 ? L(@"Report received just now") : [NSString stringWithFormat:L(@"Last report %.0f seconds ago"), age];
    }
    if (selected.pid != 0xfa65) {
        p.value = @"USB"; p.detail = L(@"USB connected"); p.symbol = @"cable.connector";
        p.hint = L(@"Battery percentage is unavailable in wired mode.");
        if (selected.received && [now timeIntervalSinceDate:selected.received] < Freshness && selected.pid == 0xfa73 && selected.state == 3)
            p.detail = L(@"USB connected · Charging indicated");
        return p;
    }
    if (!selected.received) {
        p.detail = L(@"Waiting for mouse"); p.hint = L(@"Move your mouse to wake it."); return p;
    }
    if ([now timeIntervalSinceDate:selected.received] >= Freshness) {
        p.detail = L(@"No recent battery report"); p.hint = L(@"Your mouse may be asleep. Move it to reconnect."); return p;
    }
    p.percent = @(selected.percent);
    p.value = [NSString stringWithFormat:@"%u%%", selected.percent];
    p.detail = selected.state == 3 ? L(@"Charging") : selected.state == 1 ? L(@"Running on battery") : L(@"Charging status unknown");
    unsigned level = selected.percent > 87 ? 100 : selected.percent > 62 ? 75 : selected.percent > 37 ? 50 : selected.percent > 12 ? 25 : 0;
    p.symbol = selected.state == 3 ? @"battery.100percent.bolt" : [NSString stringWithFormat:@"battery.%upercent", level];
    p.hint = @"";
    return p;
}

static long number(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    long result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberLongType, &result);
    return result;
}

static BOOL supported(IOHIDDeviceRef device) {
    long pid = number(device, CFSTR(kIOHIDProductIDKey));
    if (pid != 0xfa65 && pid != 0xfa73 && pid != 0xfa26) return NO;
    static const uint8_t signature[] = {0x05,0x0a,0x09,0x00,0xa1,0x01,0x85,0x03,0x19,0x00,0x29,0x00,0x15,0x00,0x25,0x00,0x75,0x08,0x95,0x04,0x81,0x01,0xc0};
    CFTypeRef descriptor = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDReportDescriptorKey));
    if (!descriptor || CFGetTypeID(descriptor) != CFDataGetTypeID()) return NO;
    CFIndex length = CFDataGetLength(descriptor);
    const uint8_t *bytes = CFDataGetBytePtr(descriptor);
    for (CFIndex i = 0; i + (CFIndex)sizeof signature <= length; i++)
        if (!memcmp(bytes + i, signature, sizeof signature)) return YES;
    return NO;
}

static NSTextField *label(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    return field;
}

@interface XGlyph : NSObject <NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate>
@property NSStatusItem *statusItem;
@property NSMenu *menu;
@property NSTextField *valueLabel;
@property NSTextField *detailLabel;
@property NSTextField *connectionLabel;
@property NSTextField *updatedLabel;
@property NSImageView *batteryImage;
@property NSTextField *hintLabel;
@property NSMenuItem *hintItem;
@property NSMenuItem *hintSeparator;
@property NSMenuItem *percentageItem;
@property NSMutableDictionary<NSNumber *, XGDevice *> *devices;
@property NSTimer *timer;
@property IOHIDManagerRef manager;
@property NSWindow *about;
@property NSWindow *settings;
@property NSTextField *settingsBattery;
@property NSTextField *permissionLabel;
@property NSButton *indicatorCheck;
@property NSButton *loginCheck;
@property NSTextField *loginLabel;
@property NSString *loginError;
@property NSButton *lowCheck;
@property NSButton *fullCheck;
@property NSButton *chargingCheck;
@property NSButton *stoppedCheck;
@property BOOL showIndicator;
@property BOOL notifyLow;
@property BOOL notifyFull;
@property BOOL notifyCharging;
@property BOOL notifyStopped;
@property UNNotificationSetting soundSetting;
@property UNAuthorizationStatus authorization;
@property BOOL permissionKnown;
@property NSString *notificationError;
@property NSMutableSet<NSString *> *pendingNotices;
@property BOOL showPercentage;
@property unsigned ticks;
@end

@implementation XGlyph
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"ShowPercentage": @YES, @"ShowIndicator": @NO, @"NotifyLow": @YES, @"NotifyFull": @YES, @"NotifyCharging": @YES, @"NotifyStopped": @YES}];
    self.showPercentage = [[NSUserDefaults standardUserDefaults] boolForKey:@"ShowPercentage"];
    self.showIndicator = [[NSUserDefaults standardUserDefaults] boolForKey:@"ShowIndicator"];
    self.notifyLow = [[NSUserDefaults standardUserDefaults] boolForKey:@"NotifyLow"];
    self.notifyFull = [[NSUserDefaults standardUserDefaults] boolForKey:@"NotifyFull"];
    self.notifyCharging = [[NSUserDefaults standardUserDefaults] boolForKey:@"NotifyCharging"];
    self.notifyStopped = [[NSUserDefaults standardUserDefaults] boolForKey:@"NotifyStopped"];
    self.pendingNotices = [NSMutableSet new];
    self.devices = [NSMutableDictionary new];
    self.manager = IOHIDManagerCreate(kCFAllocatorDefault, 0);
    NSDictionary *match = @{ @kIOHIDVendorIDKey: @(0x1d57) };
    IOHIDManagerSetDeviceMatching(self.manager, (__bridge CFDictionaryRef)match);
    IOHIDManagerScheduleWithRunLoop(self.manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    if (!diagnostics) {
        UNUserNotificationCenter.currentNotificationCenter.delegate = self;
        [self buildMenu];
        if (isLoginLaunch(NSAppleEventManager.sharedAppleEventManager.currentAppleEvent)) {
            [self refreshNotificationPermission];
        } else {
            [self showSettings:nil];
            [self requestNotificationPermission:nil];
        }
    }
    [self scan];
    __weak XGlyph *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        XGlyph *s = weakSelf;
        if (++s.ticks % 3 == 0) [s scan];
        if (!diagnostics && s.ticks % 30 == 0) [s refreshNotificationPermission];
        [s refresh];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    if (notificationSmoke) {
        [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.authorization = settings.authorizationStatus; self.soundSetting = settings.soundSetting; self.permissionKnown = YES;
                printf("notification authorization=%ld (2=authorized, 1=denied, 0=not determined)\n", (long)self.authorization);
                if (self.authorization == UNAuthorizationStatusAuthorized || self.authorization == UNAuthorizationStatusProvisional)
                    [self testNotification:nil];
            });
        }];
    }
    if (diagnostics) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        XGPresentation *p = present(self.devices.allValues, NSDate.date);
        printf("presentation: %s | %s | %s\n", p.value.UTF8String, p.detail.UTF8String, p.connection.UTF8String);
        [NSApp terminate:nil];
    });
}
- (void)scan {
    CFSetRef found = IOHIDManagerCopyDevices(self.manager);
    NSSet *set = CFBridgingRelease(found);
    NSMutableSet *seen = [NSMutableSet new];
    for (id object in set) {
        IOHIDDeviceRef h = (__bridge IOHIDDeviceRef)object;
        if (!supported(h)) continue;
        uint64_t identifier = 0;
        if (IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(h), &identifier) != KERN_SUCCESS) continue;
        NSNumber *key = @(identifier);
        [seen addObject:key];
        if (self.devices[key]) continue;
        XGDevice *d = [XGDevice new];
        d->handle = (IOHIDDeviceRef)CFRetain(h);
        d.notificationKey = [NSString stringWithFormat:@"NoticeHistory-%04lX-%08lX", number(h, CFSTR(kIOHIDProductIDKey)), number(h, CFSTR(kIOHIDLocationIDKey))];
        d.identifier = identifier; d.pid = (uint16_t)number(h, CFSTR(kIOHIDProductIDKey));
        d.error = IOHIDDeviceOpen(h, kIOHIDOptionsTypeNone);
        d.opened = d.error == kIOReturnSuccess;
        self.devices[key] = d;
        if (diagnostics) printf("attached pid=%04X open=%08X\n", d.pid, (unsigned)d.error);
        if (!d.opened) continue;
        __weak XGlyph *weakSelf = self;
        __weak XGDevice *weakDevice = d;
        d.changed = ^{
            [weakSelf refresh];
            [weakSelf processNotifications:weakDevice];
        };
        IOHIDDeviceRegisterInputReportCallback(h, d->buffer, sizeof d->buffer, report, (__bridge void *)d);
        IOHIDDeviceScheduleWithRunLoop(h, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    }
    for (NSNumber *key in self.devices.allKeys) if (![seen containsObject:key]) [self.devices removeObjectForKey:key];
    [self refresh];
}
- (NSMenuItem *)action:(NSString *)title selector:(SEL)selector key:(NSString *)key {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:selector keyEquivalent:key];
    item.target = self; [self.menu addItem:item]; return item;
}
- (void)buildMenu {
    self.menu = [NSMenu new]; self.menu.delegate = self;
    NSView *card = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 302, 197)];
    NSTextField *name = label(@"XGlyph", 14, NSFontWeightSemibold);
    name.frame = NSMakeRect(18, 169, 266, 20); [card addSubview:name];
    NSTextField *deviceName = label(@"DELUX M900 Pro", 12, NSFontWeightRegular);
    deviceName.textColor = NSColor.secondaryLabelColor;
    deviceName.frame = NSMakeRect(18, 147, 266, 19); [card addSubview:deviceName];
    self.batteryImage = [[NSImageView alloc] initWithFrame:NSMakeRect(19, 77, 52, 45)];
    self.batteryImage.imageScaling = NSImageScaleProportionallyUpOrDown;
    [card addSubview:self.batteryImage];
    self.valueLabel = label(@"—", 34, NSFontWeightMedium);
    self.valueLabel.frame = NSMakeRect(84, 79, 196, 45); [card addSubview:self.valueLabel];
    self.detailLabel = label(L(@"Waiting for mouse"), 12, NSFontWeightMedium);
    self.detailLabel.frame = NSMakeRect(18, 57, 270, 18); [card addSubview:self.detailLabel];
    self.connectionLabel = label(@"", 11, NSFontWeightRegular);
    self.connectionLabel.textColor = NSColor.secondaryLabelColor;
    self.connectionLabel.frame = NSMakeRect(18, 32, 270, 17); [card addSubview:self.connectionLabel];
    self.updatedLabel = label(@"", 11, NSFontWeightRegular);
    self.updatedLabel.textColor = NSColor.secondaryLabelColor;
    self.updatedLabel.frame = NSMakeRect(18, 14, 270, 17); [card addSubview:self.updatedLabel];
    NSMenuItem *header = [NSMenuItem new]; header.view = card; [self.menu addItem:header];
    self.hintSeparator = NSMenuItem.separatorItem;
    [self.menu addItem:self.hintSeparator];
    NSMenuItem *hintItem = [NSMenuItem new]; self.hintItem = hintItem;
    NSView *hintView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 302, 84)];
    self.hintLabel = [NSTextField wrappingLabelWithString:@""];
    self.hintLabel.font = [NSFont systemFontOfSize:11];
    self.hintLabel.textColor = NSColor.secondaryLabelColor;
    self.hintLabel.frame = NSMakeRect(18, 4, 266, 76);
    [hintView addSubview:self.hintLabel]; hintItem.view = hintView;
    [self.menu addItem:hintItem];
    [self.menu addItem:NSMenuItem.separatorItem];
    self.percentageItem = [self action:L(@"Show Percentage") selector:@selector(togglePercentage:) key:@""];
    [self action:L(@"Check Connection") selector:@selector(checkConnection:) key:@"r"];
    [self.menu addItem:NSMenuItem.separatorItem];
    [self action:L(@"Settings…") selector:@selector(showSettings:) key:@","];
    [self action:L(@"About XGlyph…") selector:@selector(showAbout:) key:@""];
    [self action:L(@"Quit XGlyph") selector:@selector(quit:) key:@"q"];
    [self updateIndicator];
}
- (void)updateIndicator {
    if (self.showIndicator && !self.statusItem) {
        self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        self.statusItem.menu = self.menu;
    } else if (!self.showIndicator && self.statusItem) {
        [NSStatusBar.systemStatusBar removeStatusItem:self.statusItem];
        self.statusItem = nil;
    }
}
- (void)refresh {
    XGPresentation *p = present(self.devices.allValues, NSDate.date);
    self.settingsBattery.stringValue = [NSString stringWithFormat:@"DELUX M900 Pro  ·  %@\n%@", p.value, p.detail];
    [self refreshPermissionLabel];
    NSImage *image = [NSImage imageWithSystemSymbolName:p.symbol accessibilityDescription:p.detail];
    image.template = YES;
    self.statusItem.button.image = image;
    self.statusItem.button.imagePosition = NSImageLeft;
    self.statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.statusItem.button.title = self.showPercentage ? [@" " stringByAppendingString:p.value] : @"";
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"XGlyph · %@ · %@", p.value, p.detail];
    self.statusItem.button.accessibilityLabel = self.statusItem.button.toolTip;
    self.valueLabel.stringValue = p.value; self.detailLabel.stringValue = p.detail;
    self.connectionLabel.stringValue = p.connection; self.updatedLabel.stringValue = p.updated;
    self.batteryImage.image = image;
    self.batteryImage.contentTintColor = p.percent ? (p.percent.unsignedIntValue <= 20 ? NSColor.systemOrangeColor : NSColor.systemGreenColor) : NSColor.secondaryLabelColor;
    self.hintLabel.stringValue = p.hint;
    self.hintItem.hidden = p.hint.length == 0;
    self.hintSeparator.hidden = p.hint.length == 0;
    self.percentageItem.state = self.showPercentage ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)menuWillOpen:(NSMenu *)menu { (void)menu; [self refresh]; }
- (void)togglePercentage:(id)sender {
    (void)sender; self.showPercentage = !self.showPercentage;
    [[NSUserDefaults standardUserDefaults] setBool:self.showPercentage forKey:@"ShowPercentage"];
    [self refresh];
}
- (void)checkConnection:(id)sender {
    (void)sender;
    /* Retry failed opens without interrupting a healthy stream. */
    for (NSNumber *key in self.devices.allKeys) if (!self.devices[key].opened) [self.devices removeObjectForKey:key];
    [self scan];
}
- (void)showAbout:(id)sender {
    (void)sender;
    if (!self.about) {
        self.about = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 394)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.about.title = L(@"About XGlyph"); self.about.releasedWhenClosed = NO;
        NSView *v = self.about.contentView;
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(30, 305, 52, 52)];
        icon.image = [NSImage imageNamed:@"AppIcon"]; icon.imageScaling = NSImageScaleProportionallyUpOrDown;
        [v addSubview:icon];
        NSTextField *title = label(@"XGlyph", 27, NSFontWeightSemibold);
        title.frame = NSMakeRect(100, 327, 320, 35); [v addSubview:title];
        NSTextField *subtitle = label([NSString stringWithFormat:L(@"Version %@"), NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0.3.0"], 12, NSFontWeightRegular);
        subtitle.textColor = NSColor.secondaryLabelColor; subtitle.frame = NSMakeRect(102, 305, 320, 20); [v addSubview:subtitle];
        NSTextField *description = [NSTextField wrappingLabelWithString:L(@"Mouse Battery Notifications and Indicator")];
        description.font = [NSFont systemFontOfSize:14]; description.frame = NSMakeRect(30, 235, 400, 50); [v addSubview:description];
        NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(30, 216, 400, 1)]; line.boxType = NSBoxSeparator; [v addSubview:line];
        NSTextField *heading = label(L(@"Copyright"), 13, NSFontWeightSemibold);
        heading.frame = NSMakeRect(30, 177, 400, 22); [v addSubview:heading];
        NSTextField *copyright = [NSTextField wrappingLabelWithString:L(@"Copyright © 2026 GNineteen.\nMIT License")];
        copyright.selectable = YES; copyright.frame = NSMakeRect(30, 129, 400, 40); [v addSubview:copyright];
        NSButton *email = [NSButton buttonWithTitle:@"me+xglyph@gnineteen.com" target:self action:@selector(contact:)];
        email.bezelStyle = NSBezelStyleInline; email.frame = NSMakeRect(25, 92, 240, 26); [v addSubview:email];
        NSButton *license = [NSButton buttonWithTitle:L(@"View MIT License") target:self action:@selector(showLicense:)];
        license.bezelStyle = NSBezelStyleRounded; license.frame = NSMakeRect(26, 32, 240, 30); [v addSubview:license];
        [self.about center];
    }
    if (!diagnostics) { [NSApp activateIgnoringOtherApps:YES]; [self.about makeKeyAndOrderFront:nil]; }
}
- (void)showSettings:(id)sender {
    (void)sender;
    if (!self.settings) {
        self.settings = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 752)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.settings.title = @"XGlyph"; self.settings.releasedWhenClosed = NO;
        NSView *v = self.settings.contentView;
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(26, 476, 64, 64)];
        icon.image = [NSImage imageNamed:@"AppIcon"]; icon.imageScaling = NSImageScaleProportionallyUpOrDown;
        [v addSubview:icon];
        NSTextField *title = label(@"XGlyph", 26, NSFontWeightSemibold);
        title.frame = NSMakeRect(106, 508, 380, 34); [v addSubview:title];
        NSTextField *subtitle = label(L(@"Mouse Battery Notifications and Indicator"), 12, NSFontWeightRegular);
        subtitle.textColor = NSColor.secondaryLabelColor;
        subtitle.frame = NSMakeRect(108, 480, 380, 21); [v addSubview:subtitle];
        self.settingsBattery = [NSTextField wrappingLabelWithString:@""];
        self.settingsBattery.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
        self.settingsBattery.frame = NSMakeRect(30, 412, 460, 45); [v addSubview:self.settingsBattery];
        NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(30, 394, 460, 1)]; line.boxType = NSBoxSeparator; [v addSubview:line];
        NSTextField *heading = label(L(@"Notifications"), 14, NSFontWeightSemibold);
        heading.frame = NSMakeRect(30, 354, 460, 24); [v addSubview:heading];
        self.lowCheck = [NSButton checkboxWithTitle:L(@"Low battery — 20% or less") target:self action:@selector(changePreferences:)];
        self.lowCheck.frame = NSMakeRect(30, 321, 460, 24); [v addSubview:self.lowCheck];
        self.fullCheck = [NSButton checkboxWithTitle:L(@"Battery full — 100%") target:self action:@selector(changePreferences:)];
        self.fullCheck.frame = NSMakeRect(30, 290, 460, 24); [v addSubview:self.fullCheck];
        self.permissionLabel = [NSTextField wrappingLabelWithString:@""];
        self.permissionLabel.font = [NSFont systemFontOfSize:11]; self.permissionLabel.textColor = NSColor.secondaryLabelColor;
        self.permissionLabel.frame = NSMakeRect(32, 241, 456, 40); [v addSubview:self.permissionLabel];
        NSButton *enable = [NSButton buttonWithTitle:L(@"Notification Settings…") target:self action:@selector(openNotificationSettings:)];
        enable.frame = NSMakeRect(25, 201, 200, 32); enable.bezelStyle = NSBezelStyleRounded; [v addSubview:enable];
        NSButton *test = [NSButton buttonWithTitle:L(@"Send Test") target:self action:@selector(testNotification:)];
        test.frame = NSMakeRect(240, 201, 210, 32); test.bezelStyle = NSBezelStyleRounded; [v addSubview:test];
        for (NSView *view in v.subviews) {
            if (view.frame.origin.y >= 290) {
                NSRect frame = view.frame; frame.origin.y += 72; view.frame = frame;
            }
        }
        self.chargingCheck = [NSButton checkboxWithTitle:L(@"Charging started") target:self action:@selector(changePreferences:)];
        self.chargingCheck.frame = NSMakeRect(30, 326, 460, 24); [v addSubview:self.chargingCheck];
        self.stoppedCheck = [NSButton checkboxWithTitle:L(@"Charging stopped — battery level") target:self action:@selector(changePreferences:)];
        self.stoppedCheck.frame = NSMakeRect(30, 290, 460, 24); [v addSubview:self.stoppedCheck];
        self.indicatorCheck = [NSButton checkboxWithTitle:L(@"Show battery in the menu bar") target:self action:@selector(changePreferences:)];
        self.indicatorCheck.frame = NSMakeRect(30, 151, 460, 25); [v addSubview:self.indicatorCheck];
        NSTextField *note = [NSTextField wrappingLabelWithString:L(@"XGlyph stays open when you close this window.\nOpen XGlyph again to return to settings.")];
        note.font = [NSFont systemFontOfSize:11]; note.textColor = NSColor.secondaryLabelColor;
        note.frame = NSMakeRect(32, 92, 456, 42); [v addSubview:note];
        for (NSView *view in v.subviews) {
            NSRect frame = view.frame; frame.origin.y += 110; view.frame = frame;
        }
        self.loginCheck = [NSButton checkboxWithTitle:L(@"Launch at login") target:self action:@selector(changeLoginPreference:)];
        self.loginCheck.frame = NSMakeRect(30, 151, 270, 25); [v addSubview:self.loginCheck];
        NSButton *loginSettings = [NSButton buttonWithTitle:L(@"Login Items…") target:self action:@selector(openLoginSettings:)];
        loginSettings.frame = NSMakeRect(310, 147, 180, 32); loginSettings.bezelStyle = NSBezelStyleRounded;
        [v addSubview:loginSettings];
        self.loginLabel = [NSTextField wrappingLabelWithString:@""];
        self.loginLabel.font = [NSFont systemFontOfSize:11]; self.loginLabel.textColor = NSColor.secondaryLabelColor;
        self.loginLabel.frame = NSMakeRect(32, 92, 456, 44); [v addSubview:self.loginLabel];
        NSButton *about = [NSButton buttonWithTitle:L(@"About XGlyph…") target:self action:@selector(showAbout:)];
        about.frame = NSMakeRect(25, 27, 200, 32); about.bezelStyle = NSBezelStyleRounded; [v addSubview:about];
        NSButton *quit = [NSButton buttonWithTitle:L(@"Quit XGlyph") target:self action:@selector(quit:)];
        quit.frame = NSMakeRect(313, 27, 180, 32); quit.bezelStyle = NSBezelStyleRounded; [v addSubview:quit];
        [self.settings center];
    }
    self.indicatorCheck.state = self.showIndicator ? NSControlStateValueOn : NSControlStateValueOff;
    self.lowCheck.state = self.notifyLow ? NSControlStateValueOn : NSControlStateValueOff;
    self.fullCheck.state = self.notifyFull ? NSControlStateValueOn : NSControlStateValueOff;
    self.chargingCheck.state = self.notifyCharging ? NSControlStateValueOn : NSControlStateValueOff;
    self.stoppedCheck.state = self.notifyStopped ? NSControlStateValueOn : NSControlStateValueOff;
    [self refresh];
    [self refreshLoginStatus];
    if (!diagnostics) {
        [self refreshNotificationPermission];
        [NSApp activateIgnoringOtherApps:YES]; [self.settings makeKeyAndOrderFront:nil];
    }
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    (void)sender; (void)visible; [self showSettings:nil]; return YES;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return NO; }
- (void)changePreferences:(id)sender {
    (void)sender;
    self.showIndicator = self.indicatorCheck.state == NSControlStateValueOn;
    self.notifyLow = self.lowCheck.state == NSControlStateValueOn;
    self.notifyFull = self.fullCheck.state == NSControlStateValueOn;
    self.notifyCharging = self.chargingCheck.state == NSControlStateValueOn;
    self.notifyStopped = self.stoppedCheck.state == NSControlStateValueOn;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:self.notifyStopped forKey:@"NotifyStopped"];
    [defaults setBool:self.showIndicator forKey:@"ShowIndicator"];
    [defaults setBool:self.notifyLow forKey:@"NotifyLow"];
    [defaults setBool:self.notifyFull forKey:@"NotifyFull"];
    [defaults setBool:self.notifyCharging forKey:@"NotifyCharging"];
    [self updateIndicator];
    [self refresh];
}
- (void)refreshLoginStatus {
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    self.loginCheck.state = status == SMAppServiceStatusEnabled ? NSControlStateValueOn :
        (status == SMAppServiceStatusRequiresApproval ? NSControlStateValueMixed : NSControlStateValueOff);
    NSString *message = L(@"Open XGlyph manually to receive battery notifications.");
    if (status == SMAppServiceStatusEnabled)
        message = L(@"XGlyph starts quietly when you sign in. No settings window opens.");
    else if (status == SMAppServiceStatusRequiresApproval)
        message = L(@"Allow XGlyph in macOS Login Items to finish enabling automatic launch.");
    else if (status == SMAppServiceStatusNotFound)
        message = L(@"Keep XGlyph in Applications, then enable launch at login again.");
    self.loginLabel.stringValue = self.loginError ?: message;
}
- (void)changeLoginPreference:(NSButton *)sender {
    NSError *error = nil;
    SMAppService *service = SMAppService.mainAppService;
    BOOL success = sender.state == NSControlStateValueOn ?
        [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
    self.loginError = success ? nil : [NSString stringWithFormat:L(@"Could not update launch at login. %@"), error.localizedDescription ?: L(@"Try again in Login Items.")];
    [self refreshLoginStatus];
}
- (void)openLoginSettings:(id)sender {
    (void)sender; [SMAppService openSystemSettingsLoginItems];
}
- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification; self.loginError = nil; [self refreshLoginStatus];
}
- (void)refreshPermissionLabel {
    NSString *text = L(@"Checking notification permission…");
    if (self.notificationError) text = self.notificationError;
    else if (self.permissionKnown) {
        if (self.authorization == UNAuthorizationStatusAuthorized || self.authorization == UNAuthorizationStatusProvisional)
            text = self.soundSetting == UNNotificationSettingEnabled
                ? L(@"Notifications and sound enabled. Focus or screen sharing may silence alerts.")
                : L(@"Notifications enabled, but sound is off in macOS Notification Settings.");
        else if (self.authorization == UNAuthorizationStatusDenied)
            text = L(@"Notifications are off for XGlyph. Enable them in Notification Settings.");
        else text = L(@"Allow notifications to receive battery alerts.");
    }
    self.permissionLabel.stringValue = text;
}
- (void)refreshNotificationPermission {
    if (diagnostics) return;
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.authorization = settings.authorizationStatus; self.soundSetting = settings.soundSetting; self.permissionKnown = YES;
            if ((self.authorization == UNAuthorizationStatusAuthorized || self.authorization == UNAuthorizationStatusProvisional) &&
                [self.notificationError isEqual:L(@"Could not request notification permission. Try Notification Settings.")])
                self.notificationError = nil;
            [self refreshPermissionLabel];
        });
    }];
}
- (void)requestNotificationPermission:(id)sender {
    (void)sender; if (diagnostics) return;
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.authorization = settings.authorizationStatus; self.soundSetting = settings.soundSetting; self.permissionKnown = YES;
            if (settings.authorizationStatus != UNAuthorizationStatusNotDetermined) {
                [self refreshPermissionLabel]; return;
            }
            [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                completionHandler:^(BOOL granted, NSError *error) {
                (void)granted;
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.notificationError = error ? L(@"Could not request notification permission. Try Notification Settings.") : nil;
                    [self refreshNotificationPermission];
                });
            }];
        });
    }];
}
- (void)openNotificationSettings:(id)sender {
    (void)sender;
    if (self.authorization == UNAuthorizationStatusNotDetermined) [self requestNotificationPermission:nil];
    else [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Notifications-Settings.extension"]];
}
- (void)testNotification:(id)sender {
    (void)sender; if (diagnostics && !notificationSmoke) return;
    if (self.authorization != UNAuthorizationStatusAuthorized && self.authorization != UNAuthorizationStatusProvisional) {
        [self requestNotificationPermission:nil]; return;
    }
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = L(@"XGlyph test notification");
    content.body = L(@"Your mouse battery notifications are ready.");
    content.sound = UNNotificationSound.defaultSound;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"xglyph-test" content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (notificationSmoke) printf("test notification submission: %s\n", error ? error.localizedDescription.UTF8String : "accepted");
            self.notificationError = error ? L(@"Test notification could not be submitted.") : nil;
            [self refreshPermissionLabel];
        });
    }];
}
- (void)processNotifications:(XGDevice *)device {
    if (diagnostics || !device || !device.notificationKey) return;
    BOOL wired = NO;
    for (XGDevice *d in self.devices.allValues) if (d.pid != 0xfa65) wired = YES;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *saved = [defaults dictionaryForKey:device.notificationKey];
    XGNoticeState history = { [saved[@"low"] boolValue], [saved[@"full"] boolValue] };
    XGNotice notice = xg_notice(&history, device.pid, device.percent, device.state,
        device.received && -device.received.timeIntervalSinceNow < Freshness, wired, self.notifyLow, self.notifyFull);
    NSDictionary *next = @{@"low": @(history.low_sent), @"full": @(history.full_sent)};
    if (![saved isEqual:next]) [defaults setObject:next forKey:device.notificationKey];
    if (notice == XGNoticeNone && self.notifyCharging && device.chargingStarted)
        notice = XGNoticeCharging;
    if (notice == XGNoticeNone && self.notifyStopped && device.chargingStopped)
        notice = XGNoticeStopped;
    if (notice == XGNoticeNone || !self.permissionKnown ||
        (self.authorization != UNAuthorizationStatusAuthorized && self.authorization != UNAuthorizationStatusProvisional)) return;
    NSString *key = [NSString stringWithFormat:@"%@-%u", device.notificationKey, notice];
    if ([self.pendingNotices containsObject:key]) return;
    [self.pendingNotices addObject:key];
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = notice == XGNoticeCharging ? L(@"Mouse is charging") :
        (notice == XGNoticeLow ? L(@"Mouse battery is low") : L(@"Mouse battery is full"));
    content.body = notice == XGNoticeLow
        ? [NSString stringWithFormat:L(@"DELUX M900 Pro has %u%% remaining. Time to charge."), device.percent]
        : (notice == XGNoticeCharging ? L(@"DELUX M900 Pro has started charging.") : L(@"DELUX M900 Pro has reached 100%."));
    if (notice == XGNoticeStopped) {
        content.title = L(@"Charging stopped");
        content.body = [NSString stringWithFormat:L(@"DELUX M900 Pro stopped charging at %u%%."), device.percent];
    }
    content.sound = UNNotificationSound.defaultSound;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:key content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.pendingNotices removeObject:key];
            if (!error && (notice == XGNoticeLow || notice == XGNoticeFull)) {
                NSMutableDictionary *delivered = [[defaults dictionaryForKey:device.notificationKey] mutableCopy] ?: [NSMutableDictionary new];
                delivered[notice == XGNoticeLow ? @"low" : @"full"] = @YES;
                [defaults setObject:delivered forKey:device.notificationKey];
            }
            self.notificationError = error ? L(@"A battery notification could not be submitted. Check Notification Settings.") : nil;
            [self refreshPermissionLabel];
        });
    }];
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
        withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    (void)center; (void)notification;
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList | UNNotificationPresentationOptionSound);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response
        withCompletionHandler:(void (^)(void))completionHandler {
    (void)center; (void)response;
    dispatch_async(dispatch_get_main_queue(), ^{ [self showSettings:nil]; completionHandler(); });
}
- (void)showLicense:(id)sender {
    (void)sender;
    NSURL *url = [NSBundle.mainBundle URLForResource:@"LICENSE" withExtension:@"txt"];
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
}
- (void)contact:(id)sender { (void)sender; [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"mailto:me+xglyph@gnineteen.com"]]; }
- (void)quit:(id)sender { (void)sender; [NSApp terminate:nil]; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification; [self.timer invalidate]; [self.devices removeAllObjects];
    if (self.manager) {
        IOHIDManagerUnscheduleFromRunLoop(self.manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(self.manager); self.manager = NULL;
    }
}
@end

static int selfTest(void) {
    NSAppleEventDescriptor *launch = [NSAppleEventDescriptor appleEventWithEventClass:kCoreEventClass eventID:kAEOpenApplication
        targetDescriptor:nil returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    NSCAssert(!isLoginLaunch(nil) && !isLoginLaunch(launch), @"Manual launch opens settings");
    [launch setParamDescriptor:[NSAppleEventDescriptor descriptorWithEnumCode:keyAELaunchedAsLogInItem] forKeyword:keyAEPropData];
    NSCAssert(isLoginLaunch(launch), @"Login launch remains quiet");
    [launch setParamDescriptor:[NSAppleEventDescriptor descriptorWithEnumCode:keyAELaunchedAsServiceItem] forKeyword:keyAEPropData];
    NSCAssert(isLoginLaunch(launch), @"Service launch remains quiet");
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000];
    XGDevice *radio = [XGDevice new]; radio.pid = 0xfa65; radio.opened = YES;
    radio.received = now; radio.percent = 68; radio.state = 1;
    NSCAssert([present(@[radio], now).value isEqual:@"68%"], @"Wireless percentage");
    radio.state = 3;
    NSCAssert([present(@[radio], now).detail isEqual:L(@"Charging")], L(@"Charging"));
    radio.state = 2;
    NSCAssert([present(@[radio], now).detail isEqual:L(@"Charging status unknown")], @"Unknown state");
    NSCAssert(present(@[radio], [now dateByAddingTimeInterval:30]).percent == nil, @"Expire stale percentage");
    XGDevice *wired = [XGDevice new]; wired.pid = 0xfa73; wired.opened = YES;
    wired.received = now; wired.percent = 100; wired.state = 3;
    NSCAssert(present(@[radio, wired], now).percent == nil, @"Never show wired 100 percent");
    NSCAssert([present(@[wired, radio], now).value isEqual:@"USB"], @"Wired precedence");
    NSCAssert(present(@[], now).percent == nil, @"Disconnected");
    radio.received = nil;
    NSCAssert([present(@[radio], now).detail isEqual:L(@"Waiting for mouse")], @"Waiting");
    radio.opened = NO; radio.error = kIOReturnNotPermitted;
    NSCAssert([present(@[radio], now).hint isEqual:L(@"Allow XGlyph in Privacy & Security → Input Monitoring, then reopen it.")], @"Permission error");
    /* Synthetic devices have no HID handle to close. */
    wired.opened = NO;
    puts("XGlyph state tests passed."); return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--self-test")) return selfTest();
        if (argc > 1 && !strcmp(argv[1], "--localization-check")) {
            NSString *path = [NSBundle.mainBundle pathForResource:@"Localizable" ofType:@"strings" inDirectory:nil forLocalization:@"en"];
            NSDictionary *source = [NSDictionary dictionaryWithContentsOfFile:path];
            if (!source.count) return 1;
            NSMutableDictionary *localized = [NSMutableDictionary new];
            for (NSString *key in source) localized[key] = L(key);
            NSData *data = [NSJSONSerialization dataWithJSONObject:localized options:NSJSONWritingSortedKeys error:nil];
            puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
            return 0;
        }
        if (argc > 1 && !strcmp(argv[1], "--login-status")) {
            printf("login status=%ld (0=not registered, 1=enabled, 2=requires approval, 3=not found)\n", (long)SMAppService.mainAppService.status);
            return 0;
        }
        notificationSmoke = argc > 1 && !strcmp(argv[1], "--notification-check");
        diagnostics = notificationSmoke || (argc > 1 && !strcmp(argv[1], "--diagnose"));
        setvbuf(stdout, NULL, _IOLBF, 0);
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        XGlyph *delegate = [XGlyph new]; app.delegate = delegate;
        [app run];
    }
    return 0;
}
