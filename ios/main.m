#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import "PhonePairCore.h"

@interface PhonePairController : UIViewController <NSNetServiceDelegate, UNUserNotificationCenterDelegate>
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *pinLabel;
@property(nonatomic, strong) UILabel *backgroundLabel;
@property(nonatomic, strong) UITextView *logView;
@property(nonatomic, strong) UIButton *startButton;
@property(nonatomic, strong) UIButton *stopButton;
@property(nonatomic, strong) UIButton *verifyButton;
@property(nonatomic, strong) UIButton *exportButton;
@property(nonatomic, strong) NSNetService *service;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, copy) NSString *lastPhase;
@property(nonatomic, copy) NSString *lastMessage;
@property(nonatomic, copy) NSString *lastPIN;
@property(nonatomic, strong) NSMutableString *diagnostics;
@property(nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property(nonatomic) BOOL running;
@end

@implementation PhonePairController

- (UILabel *)label:(NSString *)text size:(CGFloat)size bold:(BOOL)bold {
    UILabel *label = [UILabel new];
    label.text = text;
    label.textColor = UIColor.labelColor;
    label.numberOfLines = 0;
    label.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    label.adjustsFontForContentSizeCategory = YES;
    return label;
}

- (UIButton *)button:(NSString *)title action:(SEL)action prominent:(BOOL)prominent {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = prominent ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.tintedButtonConfiguration;
    config.title = title;
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    config.contentInsets = NSDirectionalEdgeInsetsMake(14, 16, 14, 16);
    button.configuration = config;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.backgroundTask = UIBackgroundTaskInvalid;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.tintColor = [UIColor colorWithRed:0.12 green:0.53 blue:0.89 alpha:1];
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

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48],
    ]];

    [stack addArrangedSubview:[self label:@"PhonePair" size:34 bold:YES]];
    UILabel *subtitle = [self label:@"On-device pairing · iOS 27 experiment" size:15 bold:NO];
    subtitle.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:subtitle];
    [stack addArrangedSubview:[self label:@"1. Join Wi-Fi and tap Start. Allow Local Network and Notifications.\n\n2. Open Settings → Privacy & Security → Developer Mode. Select “Pair with PhonePair on this iPhone”.\n\n3. Enter the six-digit code from the notification, then return here. If needed, switch back to see the code.\n\n4. Connect LocalDevVPN, tap Verify, then export the file and import it in StikDebug." size:16 bold:NO]];

    self.statusLabel = [self label:@"Ready. This test creates a fresh identity; it does not import your existing pairing file." size:17 bold:YES];
    [stack addArrangedSubview:self.statusLabel];
    self.pinLabel = [self label:@"— — — — — —" size:34 bold:YES];
    self.pinLabel.font = [UIFont monospacedDigitSystemFontOfSize:34 weight:UIFontWeightSemibold];
    self.pinLabel.textAlignment = NSTextAlignmentCenter;
    self.pinLabel.accessibilityLabel = @"Pairing code has not been issued";
    [stack addArrangedSubview:self.pinLabel];
    self.backgroundLabel = [self label:@"Pair promptly: iOS gives this experiment limited time while Settings is open." size:13 bold:NO];
    self.backgroundLabel.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:self.backgroundLabel];

    self.startButton = [self button:@"Start on-device pairing" action:@selector(startPairing) prominent:YES];
    self.stopButton = [self button:@"Stop" action:@selector(stopPairing) prominent:NO];
    self.verifyButton = [self button:@"Verify with LocalDevVPN" action:@selector(verifyPairing) prominent:NO];
    self.exportButton = [self button:@"Export pairing file" action:@selector(exportPairing) prominent:NO];
    for (UIButton *button in @[self.startButton,self.stopButton,self.verifyButton,self.exportButton]) [stack addArrangedSubview:button];
    [stack addArrangedSubview:[self label:@"Diagnostics" size:19 bold:YES]];
    self.logView = [UITextView new];
    self.logView.editable = NO;
    self.logView.scrollEnabled = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.logView.layer.cornerRadius = 12;
    self.logView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    self.logView.text = self.diagnostics;
    [self.logView.heightAnchor constraintGreaterThanOrEqualToConstant:130].active = YES;
    [stack addArrangedSubview:self.logView];
    [stack addArrangedSubview:[self button:@"Share diagnostics" action:@selector(shareDiagnostics) prominent:NO]];
    [stack addArrangedSubview:[self label:@"A completed pairing exchange still needs verification. Your existing StikDebug pairing is not changed by this app. Pairing keys stay on your phone unless you choose Export." size:13 bold:NO]];

    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(enterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(enterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    [self poll];
}

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
    self.logView.text = self.diagnostics;
    NSArray<NSURL *> *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    [self.diagnostics writeToURL:[documents.firstObject URLByAppendingPathComponent:@"PhonePair-diagnostics.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)startPairing {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27) {
        self.statusLabel.text = @"This experiment requires iOS 27 or newer.";
        return;
    }
    [self.service stop];
    self.service = nil;
    self.lastPhase = nil;
    self.lastMessage = nil;
    self.lastPIN = nil;
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
    if ([self.lastPhase isEqualToString:@"listening"]) self.statusLabel.text = @"Ready for Settings. Select “Pair with PhonePair on this iPhone”.";
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    if (sender != self.service) return;
    NSString *message = [NSString stringWithFormat:@"Bonjour publication failed: %@. Check Settings → Apps → PhonePair → Local Network, then retry.", errorDict];
    [self appendLog:message];
    pp_stop();
    [sender stop];
    self.service = nil;
    self.statusLabel.text = message;
}

- (void)poll {
    NSDictionary *snapshot = [self snapshot];
    NSString *phase = snapshot[@"phase"] ?: @"idle";
    NSString *message = snapshot[@"message"] ?: @"";
    BOOL running = [snapshot[@"running"] boolValue];
    BOOL changed = ![phase isEqualToString:self.lastPhase] || ![message isEqualToString:self.lastMessage];
    if (changed) {
        self.statusLabel.text = message;
        [self appendLog:[NSString stringWithFormat:@"%@: %@", phase, message]];
        self.lastPhase = phase;
        self.lastMessage = message;
    }
    NSString *pin = [snapshot[@"pin"] isKindOfClass:NSString.class] ? snapshot[@"pin"] : nil;
    if (pin.length && ![pin isEqualToString:self.lastPIN]) {
        self.lastPIN = pin;
        self.pinLabel.text = pin;
        self.pinLabel.accessibilityLabel = [NSString stringWithFormat:@"Pairing code %@", pin];
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
        self.pinLabel.text = @"— — — — — —";
        self.pinLabel.accessibilityLabel = @"No active pairing code";
        [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:@[@"phonepair-pin"]];
        [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:@[@"phonepair-pin"]];
        if (self.backgroundTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];
            self.backgroundTask = UIBackgroundTaskInvalid;
        }
    }
    self.running = running;
    self.startButton.enabled = !running;
    self.stopButton.enabled = running;
    BOOL hasFile = [NSFileManager.defaultManager fileExistsAtPath:[self.directory stringByAppendingPathComponent:@"pairingFile.plist"]];
    self.verifyButton.enabled = hasFile && !running;
    self.exportButton.enabled = hasFile && !running;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground && running) {
        NSTimeInterval seconds = UIApplication.sharedApplication.backgroundTimeRemaining;
        if (seconds < 10000) self.backgroundLabel.text = [NSString stringWithFormat:@"Background time remaining: %.0f seconds. Complete pairing now.", seconds];
    }
}

- (void)stopPairing {
    pp_stop();
    [self.service stop];
    self.service = nil;
    [self appendLog:@"Stop requested."];
}

- (void)verifyPairing {
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
    [self poll];
    if (self.backgroundTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];
        self.backgroundTask = UIBackgroundTaskInvalid;
    }
    self.backgroundLabel.text = @"Pair promptly: iOS gives this experiment limited time while Settings is open.";
}

- (void)shareItems:(NSArray *)items from:(UIView *)source {
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    share.popoverPresentationController.sourceView = source ?: self.view;
    share.popoverPresentationController.sourceRect = source ? source.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:share animated:YES completion:nil];
}

- (void)exportPairing {
    NSString *source = [self.directory stringByAppendingPathComponent:@"pairingFile.plist"];
    NSURL *target = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"PhonePair-remote-pairing.plist"]];
    NSError *error;
    NSData *data = [NSData dataWithContentsOfFile:source options:0 error:&error];
    if (!data || ![data writeToURL:target options:NSDataWritingAtomic|NSDataWritingFileProtectionComplete error:&error]) {
        self.statusLabel.text = [NSString stringWithFormat:@"Export failed: %@", error.localizedDescription];
        return;
    }
    [self shareItems:@[target] from:self.exportButton];
}

- (void)shareDiagnostics {
    [self shareItems:@[self.diagnostics.copy] from:self.logView];
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
    self.window.rootViewController = [PhonePairController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(PhonePairDelegate.class)); }
}
