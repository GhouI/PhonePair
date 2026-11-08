#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import "PhonePairCore.h"

typedef NS_ENUM(NSInteger, PPSection) {
    PPSectionStatus,
    PPSectionCode,
    PPSectionActions,
    PPSectionSteps,
    PPSectionDiagnostics,
};

typedef NS_ENUM(NSInteger, PPAction) {
    PPActionStart,
    PPActionStop,
    PPActionVerify,
    PPActionExport,
    PPActionRestart,
};

static UIColor *PPTint(void) { return [UIColor colorWithRed:0.12 green:0.53 blue:0.89 alpha:1]; }

static NSString *const PPBackgroundHint = @"Return to PhonePair promptly. iOS limits how long it can keep running while Settings is open.";

#pragma mark - Activity log

@interface PPLogViewController : UIViewController
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, copy) NSString *text;
@end

@implementation PPLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Activity Log";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(share:)];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.textView = [UITextView new];
    self.textView.editable = NO;
    self.textView.alwaysBounceVertical = YES;
    self.textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.textView.textContainerInset = UIEdgeInsetsMake(16, 12, 16, 12);
    self.textView.text = self.text;
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.textView];
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (void)setText:(NSString *)text {
    _text = [text copy];
    self.textView.text = _text;
}

- (void)share:(UIBarButtonItem *)sender {
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[self.text ?: @""] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:share animated:YES completion:nil];
}

@end

#pragma mark - Main screen

@interface PhonePairController : UITableViewController <NSNetServiceDelegate, UNUserNotificationCenterDelegate>
@property(nonatomic, strong) NSNetService *service;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, copy) NSString *lastPhase;
@property(nonatomic, copy) NSString *lastMessage;
@property(nonatomic, copy) NSString *lastPIN;
@property(nonatomic, copy) NSString *statusDetail;
@property(nonatomic, copy) NSString *statusTitleOverride;
@property(nonatomic, copy) NSString *backgroundNote;
@property(nonatomic, copy) NSString *renderedSignature;
@property(nonatomic, strong) NSMutableString *diagnostics;
@property(nonatomic, weak) PPLogViewController *logController;
@property(nonatomic, strong) NSArray<NSNumber *> *sections;
@property(nonatomic, strong) NSArray<NSNumber *> *actions;
@property(nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL hasFile;
@property(nonatomic) BOOL verified;
@property(nonatomic) BOOL exported;
@property(nonatomic) BOOL copiedPIN;
@end

@implementation PhonePairController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"PhonePair";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"cell"];
    self.backgroundTask = UIBackgroundTaskInvalid;
    self.backgroundNote = PPBackgroundHint;
    self.sections = @[];
    self.actions = @[];
    self.diagnostics = [NSMutableString stringWithString:@"PhonePair 0.1.0 experimental\n"];
    [self.diagnostics appendFormat:@"iOS %@\n", UIDevice.currentDevice.systemVersion];
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    self.directory = [[support URLByAppendingPathComponent:@"PhonePair" isDirectory:YES] path];
    NSError *directoryError;
    if (![NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionComplete} error:&directoryError]) {
        [self.diagnostics appendFormat:@"Storage error: %@\n", directoryError.localizedDescription];
    }
    NSURL *directoryURL = [NSURL fileURLWithPath:self.directory];
    [directoryURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];

    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(enterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(enterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    [self poll];
}

#pragma mark - Derived state

- (BOOL)pairingActive {
    return self.running && ([self.lastPhase isEqualToString:@"listening"] || [self.lastPhase isEqualToString:@"pin"]);
}

- (NSInteger)currentStep {
    NSString *phase = self.lastPhase;
    if (self.exported) return 5;
    if (self.verified) return 4;
    if ([phase isEqualToString:@"verifying"]) return 3;
    if ([phase isEqualToString:@"pin"]) return 2;
    if (self.running) return 1;
    if (self.hasFile) return 3;
    return 0;
}

// Returns title, symbol name (nil while busy) and symbol colour for the status row.
- (NSArray *)statusAppearance {
    NSString *phase = self.lastPhase ?: @"idle";
    UIColor *tint = PPTint();
    if (self.statusTitleOverride) return @[self.statusTitleOverride, @"exclamationmark.triangle.fill", UIColor.systemOrangeColor];
    if (self.exported) return @[@"Pairing File Exported", @"checkmark.circle.fill", UIColor.systemGreenColor];
    if ([phase isEqualToString:@"listening"]) return @[@"Waiting for Settings…", NSNull.null, tint];
    if ([phase isEqualToString:@"pin"]) return @[@"Enter the Code in Settings", @"lock.circle.fill", tint];
    if ([phase isEqualToString:@"paired"]) return @[@"Paired", @"checkmark.circle.fill", tint];
    if ([phase isEqualToString:@"verifying"]) return @[@"Verifying…", NSNull.null, tint];
    if ([phase isEqualToString:@"verified"]) return @[@"Verified", @"checkmark.circle.fill", UIColor.systemGreenColor];
    if ([phase isEqualToString:@"error"]) return @[@"Couldn’t Complete", @"exclamationmark.triangle.fill", UIColor.systemOrangeColor];
    if ([phase isEqualToString:@"stopped"]) return @[@"Stopped", @"stop.circle.fill", UIColor.systemGrayColor];
    if (self.hasFile) return @[@"Pairing File Saved", @"doc.circle.fill", tint];
    return @[@"Ready to Pair", @"iphone.radiowaves.left.and.right.circle.fill", tint];
}

- (void)refresh {
    NSMutableArray *sections = [NSMutableArray arrayWithObject:@(PPSectionStatus)];
    if (self.pairingActive) [sections addObject:@(PPSectionCode)];
    [sections addObjectsFromArray:@[@(PPSectionActions), @(PPSectionSteps), @(PPSectionDiagnostics)]];

    NSArray *actions;
    if (self.running) actions = @[@(PPActionStop)];
    else if (self.hasFile) actions = @[@(PPActionVerify), @(PPActionExport), @(PPActionRestart)];
    else actions = @[@(PPActionStart)];

    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%d%d%d%d%d|%ld|%@",
        self.lastPhase, self.statusDetail, self.statusTitleOverride, self.lastPIN, self.backgroundNote,
        self.running, self.hasFile, self.verified, self.exported, self.copiedPIN, (long)self.currentStep, sections];
    if ([signature isEqualToString:self.renderedSignature]) return;
    BOOL structural = ![sections isEqualToArray:self.sections] || ![actions isEqualToArray:self.actions];
    self.renderedSignature = signature;
    self.sections = sections;
    self.actions = actions;
    if (structural && self.view.window) {
        [UIView transitionWithView:self.tableView duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            [self.tableView reloadData];
        } completion:nil];
    } else {
        [self.tableView reloadData];
    }
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (PPSection)kind:(NSInteger)section {
    return self.sections[section].integerValue;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ([self kind:section]) {
        case PPSectionActions: return self.actions.count;
        case PPSectionSteps: return 5;
        default: return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ([self kind:section]) {
        case PPSectionCode: return @"Pairing Code";
        case PPSectionSteps: return @"How to Pair";
        case PPSectionDiagnostics: return @"Diagnostics";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch ([self kind:section]) {
        case PPSectionCode: {
            NSString *hint = self.copiedPIN ? @"Copied."
                : self.lastPIN.length ? @"Enter this code when Settings asks for it. It’s also sent as a notification. Tap the code to copy it."
                : @"The code appears after you select “Pair with PhonePair on this iPhone” in Developer Mode settings.";
            return [NSString stringWithFormat:@"%@\n\n%@", hint, self.backgroundNote];
        }
        case PPSectionActions:
            if (self.running) return nil;
            if (self.verified || self.exported) return @"Import the exported file in StikDebug. Your existing StikDebug pairing isn’t changed.";
            if (self.hasFile) return @"Connect LocalDevVPN before verifying. You can also export without verifying.";
            return @"PhonePair creates a new pairing identity on this iPhone. It doesn’t read or replace your existing pairing file.";
        case PPSectionDiagnostics:
            return @"Diagnostics record steps and errors, never keys or pairing codes. Pairing keys stay on this iPhone unless you export them.\n\nPhonePair 0.1.0 · Experimental · Requires iOS 27";
        default:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessibilityLabel = nil;
    UIListContentConfiguration *content;

    switch ([self kind:indexPath.section]) {
        case PPSectionStatus: {
            NSArray *appearance = [self statusAppearance];
            content = UIListContentConfiguration.subtitleCellConfiguration;
            content.text = appearance[0];
            content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
            content.secondaryText = self.statusDetail;
            content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            content.textToSecondaryTextVerticalPadding = 3;
            content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(12, 0, 12, 0);
            UIImageSymbolConfiguration *large = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleTitle2];
            if ([appearance[1] isKindOfClass:NSString.class]) {
                content.image = [UIImage systemImageNamed:appearance[1] withConfiguration:large];
                content.imageProperties.tintColor = appearance[2];
            } else {
                UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                [spinner startAnimating];
                cell.accessoryView = spinner;
            }
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case PPSectionCode: {
            content = UIListContentConfiguration.cellConfiguration;
            BOOL has = self.lastPIN.length == 6;
            content.text = has ? [NSString stringWithFormat:@"%@ %@", [self.lastPIN substringToIndex:3], [self.lastPIN substringFromIndex:3]] : @"––– –––";
            content.textProperties.font = [UIFont monospacedDigitSystemFontOfSize:44 weight:UIFontWeightMedium];
            content.textProperties.color = has ? UIColor.labelColor : UIColor.tertiaryLabelColor;
            content.textProperties.alignment = UIListContentTextAlignmentCenter;
            content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(14, 0, 14, 0);
            cell.selectionStyle = has ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
            cell.accessibilityLabel = has ? [NSString stringWithFormat:@"Pairing code %@", [self spokenPIN]] : @"No pairing code yet";
            break;
        }
        case PPSectionActions: {
            content = UIListContentConfiguration.cellConfiguration;
            content.textProperties.color = PPTint();
            switch ((PPAction)self.actions[indexPath.row].integerValue) {
                case PPActionStart: content.text = @"Start Pairing"; break;
                case PPActionStop:
                    content.text = [self.lastPhase isEqualToString:@"verifying"] ? @"Stop Verifying" : @"Stop Pairing";
                    content.textProperties.color = UIColor.systemRedColor;
                    break;
                case PPActionVerify: content.text = @"Verify with LocalDevVPN"; break;
                case PPActionExport: content.text = @"Export Pairing File…"; break;
                case PPActionRestart: content.text = @"Start New Pairing"; break;
            }
            break;
        }
        case PPSectionSteps: {
            NSArray<NSArray<NSString *> *> *steps = @[
                @[@"Start Pairing", @"Join Wi‑Fi, then allow Local Network and Notifications."],
                @[@"Select PhonePair in Settings", @"Privacy & Security › Developer Mode › Pair with PhonePair on this iPhone."],
                @[@"Enter the Code", @"Type the six-digit code shown here or in the notification."],
                @[@"Verify", @"Connect LocalDevVPN, then return here and tap Verify."],
                @[@"Export to StikDebug", @"Save the file, then import it in StikDebug."],
            ];
            NSInteger current = self.currentStep, row = indexPath.row;
            content = UIListContentConfiguration.subtitleCellConfiguration;
            content.text = steps[row][0];
            content.secondaryText = steps[row][1];
            content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            content.textToSecondaryTextVerticalPadding = 2;
            NSString *symbol;
            UIColor *color;
            if (row < current) { symbol = @"checkmark.circle.fill"; color = UIColor.systemGreenColor; }
            else if (row == current) { symbol = [NSString stringWithFormat:@"%ld.circle.fill", (long)row + 1]; color = PPTint(); }
            else { symbol = [NSString stringWithFormat:@"%ld.circle", (long)row + 1]; color = UIColor.tertiaryLabelColor; }
            content.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleTitle3]];
            content.imageProperties.tintColor = color;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessibilityLabel = [NSString stringWithFormat:@"Step %ld, %@%@. %@", (long)row + 1, steps[row][0],
                row < current ? @", done" : row == current ? @", current" : @"", steps[row][1]];
            break;
        }
        case PPSectionDiagnostics: {
            content = UIListContentConfiguration.valueCellConfiguration;
            content.text = @"Activity Log";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
    }
    cell.contentConfiguration = content;
    return cell;
}

- (NSString *)spokenPIN {
    NSMutableArray *digits = [NSMutableArray new];
    for (NSUInteger i = 0; i < self.lastPIN.length; i++) [digits addObject:[self.lastPIN substringWithRange:NSMakeRange(i, 1)]];
    return [digits componentsJoinedByString:@" "];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    switch ([self kind:indexPath.section]) {
        case PPSectionCode:
            if (self.lastPIN.length) {
                UIPasteboard.generalPasteboard.string = self.lastPIN;
                self.copiedPIN = YES;
                [self refresh];
            }
            break;
        case PPSectionActions:
            switch ((PPAction)self.actions[indexPath.row].integerValue) {
                case PPActionStart:
                case PPActionRestart: [self startPairing]; break;
                case PPActionStop: [self stopPairing]; break;
                case PPActionVerify: [self verifyPairing]; break;
                case PPActionExport: [self exportPairingFrom:cell]; break;
            }
            break;
        case PPSectionDiagnostics: {
            PPLogViewController *log = [PPLogViewController new];
            log.text = self.diagnostics;
            self.logController = log;
            [self.navigationController pushViewController:log animated:YES];
            break;
        }
        default:
            break;
    }
}

#pragma mark - Pairing

- (NSDictionary *)snapshot {
    char *raw = pp_snapshot();
    if (!raw) return @{};
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];
    pp_free(raw);
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] ?: @{};
}

- (void)appendLog:(NSString *)message {
    if (!message.length) return;
    NSDateFormatter *format = [NSDateFormatter new];
    format.dateFormat = @"HH:mm:ss";
    [self.diagnostics appendFormat:@"[%@] %@\n", [format stringFromDate:NSDate.date], message];
    self.logController.text = self.diagnostics;
    NSArray<NSURL *> *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    [self.diagnostics writeToURL:[documents.firstObject URLByAppendingPathComponent:@"PhonePair-diagnostics.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)startPairing {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27) {
        self.statusTitleOverride = @"Requires iOS 27";
        self.statusDetail = @"This experiment requires iOS 27 or newer.";
        [self refresh];
        return;
    }
    [self.service stop];
    self.service = nil;
    self.lastPhase = nil;
    self.lastMessage = nil;
    self.lastPIN = nil;
    self.statusTitleOverride = nil;
    self.verified = NO;
    self.exported = NO;
    self.copiedPIN = NO;
    UNUserNotificationCenter *notifications = UNUserNotificationCenter.currentNotificationCenter;
    [notifications requestAuthorizationWithOptions:UNAuthorizationOptionAlert|UNAuthorizationOptionSound completionHandler:^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) [self appendLog:@"Notifications are unavailable; return to PhonePair to read the pairing code."];
        });
    }];
    if (pp_start(self.directory.UTF8String)) {
        NSDictionary *snapshot = [self snapshot];
        NSNetService *service = [[NSNetService alloc] initWithDomain:@"local." type:snapshot[@"service_type"] name:snapshot[@"identifier"] port:[snapshot[@"port"] intValue]];
        NSMutableDictionary<NSString *, NSData *> *txt = [NSMutableDictionary new];
        [snapshot[@"txt"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            txt[key] = [value dataUsingEncoding:NSUTF8StringEncoding];
        }];
        [service setTXTRecordData:[NSNetService dataFromTXTRecordDictionary:txt]];
        service.delegate = self;
        self.service = service;
        [service publish];
        [self appendLog:[NSString stringWithFormat:@"Started a fresh identity; TCP port %@. Publishing Bonjour service.", snapshot[@"port"]]];
    }
    [self poll];
}

- (void)netServiceDidPublish:(NSNetService *)sender {
    if (sender != self.service) return;
    [self appendLog:@"Bonjour publication succeeded. Look for PhonePair on this iPhone in Developer Mode settings."];
    if ([self.lastPhase isEqualToString:@"listening"]) {
        self.statusDetail = @"Open Settings › Privacy & Security › Developer Mode and select “Pair with PhonePair on this iPhone”.";
        [self refresh];
    }
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    if (sender != self.service) return;
    NSString *message = [NSString stringWithFormat:@"Bonjour publication failed: %@. Check Settings → Apps → PhonePair → Local Network, then retry.", errorDict];
    [self appendLog:message];
    pp_stop();
    [sender stop];
    self.service = nil;
    self.statusTitleOverride = @"Local Network Unavailable";
    self.statusDetail = @"Allow Local Network for PhonePair in Settings › Apps › PhonePair, then try again.";
    [self refresh];
}

- (void)poll {
    NSDictionary *snapshot = [self snapshot];
    NSString *phase = snapshot[@"phase"] ?: @"idle";
    NSString *message = snapshot[@"message"] ?: @"";
    BOOL running = [snapshot[@"running"] boolValue];
    BOOL changed = ![phase isEqualToString:self.lastPhase] || ![message isEqualToString:self.lastMessage];
    if (changed) {
        if (self.lastPhase && ![phase isEqualToString:self.lastPhase]) {
            UINotificationFeedbackGenerator *haptics = [UINotificationFeedbackGenerator new];
            if ([phase isEqualToString:@"error"]) [haptics notificationOccurred:UINotificationFeedbackTypeError];
            else if ([phase isEqualToString:@"paired"] || [phase isEqualToString:@"verified"]) [haptics notificationOccurred:UINotificationFeedbackTypeSuccess];
        }
        if ([phase isEqualToString:@"verified"]) self.verified = YES;
        if (!self.statusTitleOverride) self.statusDetail = message;
        [self appendLog:[NSString stringWithFormat:@"%@: %@", phase, message]];
        self.lastPhase = phase;
        self.lastMessage = message;
    }
    NSString *pin = [snapshot[@"pin"] isKindOfClass:NSString.class] ? snapshot[@"pin"] : nil;
    if (pin.length && ![pin isEqualToString:self.lastPIN]) {
        self.lastPIN = pin;
        self.copiedPIN = NO;
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = @"PhonePair pairing code";
        content.body = [NSString stringWithFormat:@"Enter %@ in the iOS pairing prompt.", pin];
        content.sound = UNNotificationSound.defaultSound;
        [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:[UNNotificationRequest requestWithIdentifier:@"phonepair-pin" content:content trigger:nil] withCompletionHandler:^(NSError *error) {
            if (error) dispatch_async(dispatch_get_main_queue(), ^{ [self appendLog:[NSString stringWithFormat:@"Code notification failed: %@", error.localizedDescription]]; });
        }];
    }
    if (!running) {
        [self.service stop];
        self.service = nil;
        [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:@[@"phonepair-pin"]];
        [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:@[@"phonepair-pin"]];
        if (self.backgroundTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];
            self.backgroundTask = UIBackgroundTaskInvalid;
        }
    }
    self.running = running;
    self.hasFile = [NSFileManager.defaultManager fileExistsAtPath:[self.directory stringByAppendingPathComponent:@"pairingFile.plist"]];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground && running) {
        NSTimeInterval seconds = UIApplication.sharedApplication.backgroundTimeRemaining;
        if (seconds < 10000) self.backgroundNote = [NSString stringWithFormat:@"Background time remaining: %.0f seconds. Complete pairing now.", seconds];
    }
    [self refresh];
}

- (void)stopPairing {
    pp_stop();
    [self.service stop];
    self.service = nil;
    [self appendLog:@"Stop requested."];
}

- (void)verifyPairing {
    self.verified = NO;
    self.exported = NO;
    self.statusTitleOverride = nil;
    pp_verify(self.directory.UTF8String);
    [self poll];
}

- (void)enterBackground {
    if (!self.running || self.backgroundTask != UIBackgroundTaskInvalid) return;
    self.backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Complete user-approved pairing" expirationHandler:^{
        [self appendLog:@"iOS background time expired. Return to PhonePair and retry; no incomplete record is exported."];
        pp_stop();
        [self.service stop];
        self.service = nil;
        if (self.backgroundTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];
            self.backgroundTask = UIBackgroundTaskInvalid;
        }
    }];
    [self appendLog:@"Settings may now approve the pairing while PhonePair has background time."];
}

- (void)enterForeground {
    self.backgroundNote = PPBackgroundHint;
    [self poll];
    if (self.backgroundTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];
        self.backgroundTask = UIBackgroundTaskInvalid;
    }
}

- (void)exportPairingFrom:(UIView *)sourceView {
    NSString *source = [self.directory stringByAppendingPathComponent:@"pairingFile.plist"];
    NSURL *target = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"PhonePair-remote-pairing.plist"]];
    NSError *error;
    NSData *data = [NSData dataWithContentsOfFile:source options:0 error:&error];
    if (!data || ![data writeToURL:target options:NSDataWritingAtomic|NSDataWritingFileProtectionComplete error:&error]) {
        self.statusTitleOverride = @"Couldn’t Export";
        self.statusDetail = error.localizedDescription;
        [self refresh];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[target] applicationActivities:nil];
    share.popoverPresentationController.sourceView = sourceView ?: self.view;
    share.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *returnedItems, NSError *activityError) {
        if (!completed) return;
        self.exported = YES;
        self.statusDetail = @"Import the file in StikDebug, then try enabling JIT.";
        [self appendLog:@"Pairing file exported."];
        [self refresh];
    };
    [self presentViewController:share animated:YES completion:nil];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner|UNNotificationPresentationOptionSound);
}

@end

@interface PhonePairDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation PhonePairDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[PhonePairController new]];
    navigation.navigationBar.prefersLargeTitles = YES;
    navigation.view.tintColor = PPTint();
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(PhonePairDelegate.class)); }
}
