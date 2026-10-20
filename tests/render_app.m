/* Render the actual views without opening HID devices or showing windows. */
#define main xglyph_main
#include "../app/XGlyph.m"
#undef main

static void saveView(NSView *view, NSString *path) {
    [view layoutSubtreeIfNeeded];
    for (NSView *child in view.subviews) {
        if ([child isKindOfClass:NSButton.class]) {
            NSButton *button = (NSButton *)child;
            NSCAssert(button.cell.cellSize.width <= button.frame.size.width + 1,
                @"Clipped button: %@ (%f > %f)", button.title, button.cell.cellSize.width, button.frame.size.width);
        } else if ([child isKindOfClass:NSTextField.class]) {
            NSTextField *field = (NSTextField *)child;
            NSSize needed = [field.cell cellSizeForBounds:NSMakeRect(0, 0, field.frame.size.width, 10000)];
            NSCAssert(needed.height <= field.frame.size.height + 1,
                @"Clipped text: %@ (%f > %f)", field.stringValue, needed.height, field.frame.size.height);
        }
    }
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSCAssert([png writeToFile:path atomically:YES], @"Save preview");
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication]; diagnostics = YES;
        NSString *directory = [@"build/localized-previews" stringByAppendingPathComponent:NSBundle.mainBundle.preferredLocalizations.firstObject];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        XGlyph *app = [XGlyph new];
        NSImage *icon = [[NSImage alloc] initWithContentsOfFile:@"app/Assets/XGlyph-icon.png"];
        [icon setName:@"AppIcon"];
        app.devices = [NSMutableDictionary new]; app.showPercentage = YES;
        app.notifyLow = YES; app.notifyFull = YES; app.notifyCharging = YES; app.notifyStopped = YES; app.permissionKnown = YES;
        app.soundSetting = UNNotificationSettingEnabled;
        app.authorization = UNAuthorizationStatusAuthorized;
        XGDevice *radio = [XGDevice new]; radio.pid = 0xfa65; radio.opened = YES;
        radio.received = NSDate.date; radio.percent = 84; radio.state = 1;
        app.devices[@1] = radio;
        [app buildMenu]; [app refresh];
        NSView *card = [app.menu itemAtIndex:0].view;
        NSWindow *host = [[NSWindow alloc] initWithContentRect:card.bounds styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        host.contentView = card;
        saveView(card, [directory stringByAppendingPathComponent:@"menu.png"]);
        [app showAbout:nil];
        saveView(app.about.contentView, [directory stringByAppendingPathComponent:@"about.png"]);
        [app showSettings:nil];
        saveView(app.settings.contentView, [directory stringByAppendingPathComponent:@"settings.png"]);
        radio.opened = NO;
        puts("Rendered actual menu card and About window using a simulated 84% sample.");
    }
    return 0;
}
