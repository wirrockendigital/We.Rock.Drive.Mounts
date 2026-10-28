#import <Cocoa/Cocoa.h>
#import <FinderSync/FinderSync.h>
#import <os/log.h>
#import <pwd.h>
#import <unistd.h>

// WRDMFinderSync adds one generic Finder handoff without owning transfer execution.
@interface WRDMFinderSync : FIFinderSync
@end

@implementation WRDMFinderSync

// init monitors the user's home and mounted volumes so files and folders receive the contextual action.
- (instancetype)init {
    self = [super init];
    if (self) {
        // Resolve the login home outside the sandbox container so Finder selections under Desktop and Downloads are covered.
        struct passwd *userRecord = getpwuid(getuid());
        NSString *homePath = userRecord != NULL && userRecord->pw_dir != NULL
            ? [NSString stringWithUTF8String:userRecord->pw_dir]
            : nil;
        NSMutableSet<NSURL *> *directories = [NSMutableSet set];
        if (homePath.length > 0) {
            [directories addObject:[NSURL fileURLWithPath:homePath isDirectory:YES]];
        }
        NSURL *volumesURL = [NSURL fileURLWithPath:@"/Volumes" isDirectory:YES];
        [directories addObject:volumesURL];
        [FIFinderSyncController defaultController].directoryURLs = directories;
    }
    return self;
}

// menuForMenuKind returns a direct action only for selected Finder items.
- (NSMenu *)menuForMenuKind:(FIMenuKind)whichMenu {
    if (whichMenu != FIMenuKindContextualMenuForItems) {
        return nil;
    }
    NSArray<NSURL *> *selectedURLs = [FIFinderSyncController defaultController].selectedItemURLs;
    if (selectedURLs.count == 0) {
        return nil;
    }
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"We Rock Transfer"];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"We Rock Transfer…" action:@selector(openTransfer:) keyEquivalent:@""];
    item.target = self;
    item.image = [NSImage imageWithSystemSymbolName:@"arrow.left.arrow.right.square" accessibilityDescription:@"We Rock Transfer"];
    [menu addItem:item];
    return menu;
}

// openTransfer serializes Finder selections into the main app's registered URL route.
- (void)openTransfer:(id)sender {
    NSArray<NSURL *> *selectedURLs = [FIFinderSyncController defaultController].selectedItemURLs;
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURL *url in selectedURLs) {
        if (url.isFileURL && url.path.length > 0) {
            [items addObject:[NSURLQueryItem queryItemWithName:@"source" value:url.path]];
        }
    }
    if (items.count == 0) {
        [self showHandoffError:@"No local files or folders were selected."];
        return;
    }
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"wrdm-transfer";
    components.host = @"open";
    components.queryItems = items;
    if (components.URL == nil || ![[NSWorkspace sharedWorkspace] openURL:components.URL]) {
        os_log_error(OS_LOG_DEFAULT, "Finder transfer handoff could not be opened");
        [self showHandoffError:@"We Rock Drive Mounts could not open the transfer dialog."];
    } else {
        // Log only the source count so operational paths never enter the unified log.
        os_log_info(OS_LOG_DEFAULT, "Finder transfer handoff opened with %{public}lu source(s)", (unsigned long)items.count);
    }
}

// showHandoffError keeps extension failures understandable without retaining operational state.
- (void)showHandoffError:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"We Rock Transfer";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

@end
