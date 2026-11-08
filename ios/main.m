#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import "PhonePairCore.h"

typedef NS_ENUM(NSInteger, PPAction) {
    PPActionNone,
    PPActionStart,
    PPActionStop,
    PPActionVerify,
    PPActionExport,
    PPActionOpenSettings,
};

typedef NS_ENUM(NSInteger, PPProblem) {
    PPProblemNone,
    PPProblemUnsupportedOS,
    PPProblemLocalNetwork,
};

// What sits at the top of the main screen: an SF Symbol, a spinner or the pairing code.
typedef NS_ENUM(NSInteger, PPHero) {
    PPHeroSymbol,
    PPHeroSpinner,
    PPHeroCode,
};

static UIColor *PPTint(void) { return [UIColor colorWithRed:0.12 green:0.53 blue:0.89 alpha:1]; }

static NSString *const PPBackgroundHint = @"Return here promptly. Background time is limited.";

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

#pragma mark - How to Pair

@interface PPGuideViewController : UITableViewController
@end

@implementation PPGuideViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"How to Pair";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.tableView.allowsSelection = NO;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"cell"];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSArray<NSArray<NSString *> *> *)steps {
    return @[
        @[@"Start Pairing", @"Join Wi‑Fi, then allow Local Network and Notifications."],
        @[@"Open Developer Mode", @"In Settings, go to Privacy & Security › Developer Mode and tap “Pair with PhonePair on this iPhone.”"],
        @[@"Enter the Code", @"Type the six-digit code from PhonePair or its notification, then return promptly."],
        @[@"Verify", @"Connect LocalDevVPN, then tap Verify with LocalDevVPN."],
        @[@"Import in StikDebug", @"Export the pairing file and import it in StikDebug."],
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)self.steps.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? @"About" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"PhonePair creates a new pairing identity on this iPhone. It doesn’t read or replace your existing StikDebug pairing.";
    return @"Diagnostics record steps and errors, never keys or pairing codes. Pairing keys stay on this iPhone unless you export them.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    UIListContentConfiguration *content;
    if (indexPath.section == 0) {
        NSArray<NSString *> *step = self.steps[indexPath.row];
        content = UIListContentConfiguration.subtitleCellConfiguration;
        content.text = step[0];
        content.secondaryText = step[1];
        content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        content.textToSecondaryTextVerticalPadding = 2;
        NSString *symbol = [NSString stringWithFormat:@"%ld.circle", (long)indexPath.row + 1];
        content.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleTitle3]];
        content.imageProperties.tintColor = PPTint();
        cell.accessibilityLabel = [NSString stringWithFormat:@"Step %ld, %@. %@", (long)indexPath.row + 1, step[0], step[1]];
    } else {
        NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0.1.0";
        content = UIListContentConfiguration.valueCellConfiguration;
        content.text = @"Version";
        content.secondaryText = [NSString stringWithFormat:@"%@ (Experimental)", version];
        cell.accessibilityLabel = nil;
    }
    cell.contentConfiguration = content;
    return cell;
}

@end

#pragma mark - Main screen

@interface PhonePairController : UIViewController <NSNetServiceDelegate, UNUserNotificationCenterDelegate>
@property(nonatomic, strong) NSNetService *service;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, copy) NSString *lastPhase;
@property(nonatomic, copy) NSString *lastMessage;
@property(nonatomic, copy) NSString *lastPIN;
@property(nonatomic, copy) NSString *backgroundNote;
@property(nonatomic, strong) NSMutableString *diagnostics;
@property(nonatomic, weak) PPLogViewController *logController;
@property(nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL hasFile;
@property(nonatomic) BOOL published;
@property(nonatomic) BOOL verifyRequested;
@property(nonatomic) BOOL verified;
@property(nonatomic) BOOL exported;
@property(nonatomic) BOOL copiedPIN;
@property(nonatomic) PPProblem problem;

@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIImageView *symbolView;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UILabel *codeLabel;
@property(nonatomic, strong) UILabel *headlineLabel;
@property(nonatomic, strong) UILabel *messageLabel;
@property(nonatomic, strong) UIButton *codeCopyButton;
@property(nonatomic, strong) UILabel *footnoteLabel;
@property(nonatomic, strong) UIButton *primaryButton;
@property(nonatomic, strong) UIButton *secondaryButton;
@property(nonatomic, copy) NSArray *rendered;
@property(nonatomic, copy) NSString *renderedState;
@property(nonatomic, copy) NSArray *renderedButtons;
@end

@implementation PhonePairController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"PhonePair";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.backgroundTask = UIBackgroundTaskInvalid;
    self.backgroundNote = PPBackgroundHint;
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

    [self buildInterface];

    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(enterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(enterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    [self poll];
}

#pragma mark - Interface

- (UILabel *)labelWithFont:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.font = font;
    label.textColor = color;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.adjustsFontForContentSizeCategory = YES;
    return label;
}

- (UIButton *)buttonWithConfiguration:(UIButtonConfiguration *)config textStyle:(UIFontTextStyle)style action:(SEL)action {
    config.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attributes) {
        NSMutableDictionary<NSAttributedStringKey, id> *updated = [attributes mutableCopy];
        updated[NSFontAttributeName] = [UIFont preferredFontForTextStyle:style];
        return updated;
    };
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildInterface {
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    __weak PhonePairController *weakSelf = self;
    UIDeferredMenuElement *menuItems = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        completion([weakSelf menuElements] ?: @[]);
    }];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithChildren:@[menuItems]]];
    more.accessibilityLabel = @"More";
    self.navigationItem.rightBarButtonItem = more;

    // Top of the content: one of a symbol, a spinner or the pairing code, all centred in the same slot.
    self.symbolView = [UIImageView new];
    self.symbolView.contentMode = UIViewContentModeCenter;
    self.symbolView.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:60 weight:UIImageSymbolWeightRegular];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.hidesWhenStopped = YES;
    UIFont *codeFont = [UIFont monospacedDigitSystemFontOfSize:56 weight:UIFontWeightMedium];
    self.codeLabel = [self labelWithFont:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle] scaledFontForFont:codeFont maximumPointSize:96] color:UIColor.labelColor];
    self.codeLabel.numberOfLines = 1;
    self.codeLabel.adjustsFontSizeToFitWidth = YES;
    self.codeLabel.minimumScaleFactor = 0.5;
    self.codeLabel.userInteractionEnabled = YES;
    [self.codeLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyPIN)]];
    UIView *hero = [UIView new];
    for (UIView *view in @[self.symbolView, self.spinner, self.codeLabel]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [hero addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.centerXAnchor constraintEqualToAnchor:hero.centerXAnchor],
            [view.centerYAnchor constraintEqualToAnchor:hero.centerYAnchor],
            [view.topAnchor constraintGreaterThanOrEqualToAnchor:hero.topAnchor],
            [view.leadingAnchor constraintGreaterThanOrEqualToAnchor:hero.leadingAnchor],
        ]];
    }
    NSLayoutConstraint *heroHeight = [hero.heightAnchor constraintEqualToConstant:72];
    heroHeight.priority = UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[heroHeight, [hero.heightAnchor constraintGreaterThanOrEqualToConstant:72]]];

    UIFont *headlineFont = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle1] scaledFontForFont:[UIFont systemFontOfSize:28 weight:UIFontWeightBold]];
    self.headlineLabel = [self labelWithFont:headlineFont color:UIColor.labelColor];
    self.headlineLabel.accessibilityTraits |= UIAccessibilityTraitHeader;
    self.messageLabel = [self labelWithFont:[UIFont preferredFontForTextStyle:UIFontTextStyleBody] color:UIColor.secondaryLabelColor];

    UIButtonConfiguration *copyConfig = UIButtonConfiguration.plainButtonConfiguration;
    copyConfig.imagePadding = 6;
    copyConfig.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleSubheadline];
    self.codeCopyButton = [self buttonWithConfiguration:copyConfig textStyle:UIFontTextStyleSubheadline action:@selector(copyPIN)];

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[hero, self.headlineLabel, self.messageLabel, self.codeCopyButton]];
    content.axis = UILayoutConstraintAxisVertical;
    content.alignment = UIStackViewAlignmentCenter;
    [content setCustomSpacing:16 afterView:hero];
    [content setCustomSpacing:8 afterView:self.headlineLabel];
    [content setCustomSpacing:10 afterView:self.messageLabel];
    content.translatesAutoresizingMaskIntoConstraints = NO;

    // The bottom tray holds the background-time note and up to two buttons.
    self.footnoteLabel = [self labelWithFont:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote] color:UIColor.secondaryLabelColor];
    UIButtonConfiguration *primaryConfig = UIButtonConfiguration.filledButtonConfiguration;
    primaryConfig.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    primaryConfig.contentInsets = NSDirectionalEdgeInsetsMake(15, 20, 15, 20);
    self.primaryButton = [self buttonWithConfiguration:primaryConfig textStyle:UIFontTextStyleHeadline action:@selector(buttonTapped:)];
    UIButtonConfiguration *secondaryConfig = UIButtonConfiguration.plainButtonConfiguration;
    secondaryConfig.contentInsets = NSDirectionalEdgeInsetsMake(12, 20, 12, 20);
    self.secondaryButton = [self buttonWithConfiguration:secondaryConfig textStyle:UIFontTextStyleBody action:@selector(buttonTapped:)];
    UIStackView *tray = [[UIStackView alloc] initWithArrangedSubviews:@[self.footnoteLabel, self.primaryButton, self.secondaryButton]];
    tray.axis = UILayoutConstraintAxisVertical;
    tray.spacing = 6;
    [tray setCustomSpacing:16 afterView:self.footnoteLabel];
    tray.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:tray];

    // Content scrolls only when Dynamic Type makes it taller than the screen; otherwise it sits centred.
    self.scrollView = [UIScrollView new];
    self.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];
    [self setContentScrollView:self.scrollView forEdge:NSDirectionalRectEdgeTop];
    UIView *canvas = [UIView new];
    canvas.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:canvas];
    [canvas addSubview:content];

    UILayoutGuide *frame = self.scrollView.frameLayoutGuide, *scrolled = self.scrollView.contentLayoutGuide;
    NSLayoutConstraint *canvasHeight = [canvas.heightAnchor constraintEqualToAnchor:frame.heightAnchor];
    canvasHeight.priority = 700;
    NSLayoutConstraint *centred = [content.centerYAnchor constraintEqualToAnchor:canvas.centerYAnchor constant:-32];
    centred.priority = 500;
    NSLayoutConstraint *contentWidth = [content.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-64];
    contentWidth.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *trayWidth = [tray.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-48];
    trayWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [tray.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [tray.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [tray.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
        [tray.widthAnchor constraintLessThanOrEqualToConstant:420],
        trayWidth,

        [self.scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:tray.topAnchor constant:-8],

        [canvas.topAnchor constraintEqualToAnchor:scrolled.topAnchor],
        [canvas.bottomAnchor constraintEqualToAnchor:scrolled.bottomAnchor],
        [canvas.leadingAnchor constraintEqualToAnchor:scrolled.leadingAnchor],
        [canvas.trailingAnchor constraintEqualToAnchor:scrolled.trailingAnchor],
        [canvas.widthAnchor constraintEqualToAnchor:frame.widthAnchor],
        [canvas.heightAnchor constraintGreaterThanOrEqualToAnchor:frame.heightAnchor],
        canvasHeight,

        [content.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [content.topAnchor constraintGreaterThanOrEqualToAnchor:canvas.topAnchor constant:16],
        [content.bottomAnchor constraintLessThanOrEqualToAnchor:canvas.bottomAnchor constant:-16],
        [content.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:32],
        [content.widthAnchor constraintLessThanOrEqualToConstant:400],
        contentWidth,
        centred,
        [hero.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [self.headlineLabel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [self.messageLabel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
    ]];
}

- (NSArray<UIMenuElement *> *)menuElements {
    __weak PhonePairController *weakSelf = self;
    NSMutableArray<UIMenuElement *> *elements = [NSMutableArray new];
    // With a saved file, offer the file actions that aren't already buttons on screen, so none is ever out of reach.
    if (!self.running && self.hasFile) {
        NSArray *onScreen = self.renderedButtons.count == 4 ? @[self.renderedButtons[0], self.renderedButtons[2]] : @[];
        NSMutableArray<UIMenuElement *> *fileActions = [NSMutableArray new];
        if (![onScreen containsObject:@(PPActionVerify)]) {
            [fileActions addObject:[UIAction actionWithTitle:@"Verify with LocalDevVPN" image:[UIImage systemImageNamed:@"checkmark.shield"] identifier:nil handler:^(__kindof UIAction *action) {
                [weakSelf verifyPairing];
            }]];
        }
        if (![onScreen containsObject:@(PPActionExport)]) {
            [fileActions addObject:[UIAction actionWithTitle:@"Export Pairing File" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__kindof UIAction *action) {
                [weakSelf exportPairingFrom:nil];
            }]];
        }
        if (![onScreen containsObject:@(PPActionStart)]) {
            [fileActions addObject:[UIAction actionWithTitle:@"Start New Pairing" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(__kindof UIAction *action) {
                [weakSelf startPairing];
            }]];
        }
        if (fileActions.count) [elements addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:fileActions]];
    }
    [elements addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
        [UIAction actionWithTitle:@"How to Pair" image:[UIImage systemImageNamed:@"questionmark.circle"] identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf showGuide];
        }],
        [UIAction actionWithTitle:@"Activity Log" image:[UIImage systemImageNamed:@"doc.text"] identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf showLog];
        }],
    ]]];
    return elements;
}

- (void)showGuide {
    UINavigationController *guide = [[UINavigationController alloc] initWithRootViewController:[PPGuideViewController new]];
    [self presentViewController:guide animated:YES completion:nil];
}

- (void)showLog {
    PPLogViewController *log = [PPLogViewController new];
    log.text = self.diagnostics;
    self.logController = log;
    [self.navigationController pushViewController:log animated:YES];
}

#pragma mark - State

- (NSString *)formattedPIN {
    if (self.lastPIN.length != 6) return self.lastPIN ?: @"";
    return [NSString stringWithFormat:@"%@ %@", [self.lastPIN substringToIndex:3], [self.lastPIN substringFromIndex:3]];
}

- (NSString *)spokenPIN {
    NSMutableArray *digits = [NSMutableArray new];
    for (NSUInteger i = 0; i < self.lastPIN.length; i++) [digits addObject:[self.lastPIN substringWithRange:NSMakeRange(i, 1)]];
    return [digits componentsJoinedByString:@" "];
}

// Works out what the main screen shows. Called on every poll; the views are only touched when something changed.
- (void)refresh {
    if (!self.isViewLoaded) return;
    NSString *phase = self.lastPhase ?: @"idle";
    NSString *state, *symbol = @"", *title, *message = @"", *footnote = @"";
    NSString *primaryTitle = @"", *secondaryTitle = @"";
    PPAction primary = PPActionNone, secondary = PPActionNone;
    PPHero hero = PPHeroSymbol;
    UIColor *color = PPTint();

    if (self.problem == PPProblemUnsupportedOS) {
        state = @"unsupported";
        symbol = @"exclamationmark.triangle.fill";
        color = UIColor.systemOrangeColor;
        title = @"Requires iOS 27";
        message = @"PhonePair needs iOS 27 or later.";
    } else if (self.problem == PPProblemLocalNetwork) {
        state = @"local-network";
        symbol = @"wifi.exclamationmark";
        color = UIColor.systemOrangeColor;
        title = @"Local Network Unavailable";
        message = @"Allow Local Network for PhonePair in Settings, then try again.";
        if (!self.running) {
            primary = PPActionStart; primaryTitle = @"Try Again";
            secondary = PPActionOpenSettings; secondaryTitle = @"Open Settings";
        }
    } else if (self.running && [phase isEqualToString:@"verifying"]) {
        state = @"verifying";
        hero = PPHeroSpinner;
        title = @"Verifying…";
        message = @"Checking the pairing through LocalDevVPN.";
        secondary = PPActionStop; secondaryTitle = @"Stop Verifying";
    } else if (self.running) {
        if ([phase isEqualToString:@"pin"] && self.lastPIN.length) {
            state = @"pin";
            hero = PPHeroCode;
            title = @"Enter Code in Settings";
            message = @"It’s also shown in a notification.";
        } else if (self.published || [phase isEqualToString:@"connected"] || [phase isEqualToString:@"pin"]) {
            state = @"settings";
            symbol = @"gear";
            title = @"Continue in Settings";
            message = @"Go to Privacy & Security › Developer Mode and tap “Pair with PhonePair on this iPhone.”";
        } else {
            state = @"starting";
            hero = PPHeroSpinner;
            title = @"Starting…";
        }
        footnote = self.backgroundNote ?: @"";
        secondary = PPActionStop; secondaryTitle = @"Stop Pairing";
    } else if (self.exported) {
        state = @"exported";
        symbol = @"checkmark.circle.fill";
        color = UIColor.systemGreenColor;
        title = @"Pairing File Exported";
        message = @"Import it in StikDebug, then try enabling JIT.";
        secondary = PPActionExport; secondaryTitle = @"Export Again";
    } else if ([phase isEqualToString:@"error"]) {
        BOOL verifyFailed = self.verifyRequested && self.hasFile;
        state = verifyFailed ? @"verify-error" : @"pair-error";
        symbol = @"exclamationmark.triangle.fill";
        color = UIColor.systemOrangeColor;
        title = verifyFailed ? @"Couldn’t Verify" : @"Couldn’t Pair";
        message = self.lastMessage.length ? self.lastMessage : @"See the activity log for details.";
        primary = verifyFailed ? PPActionVerify : PPActionStart; primaryTitle = @"Try Again";
        if (verifyFailed) { secondary = PPActionExport; secondaryTitle = @"Export Pairing File"; }
    } else if (self.verified) {
        state = @"verified";
        symbol = @"checkmark.circle.fill";
        color = UIColor.systemGreenColor;
        title = @"Pairing Verified";
        message = @"Export the pairing file, then import it in StikDebug.";
        primary = PPActionExport; primaryTitle = @"Export Pairing File";
    } else if (self.hasFile) {
        state = @"paired";
        symbol = @"checkmark.circle";
        title = @"Paired";
        message = @"Connect LocalDevVPN, then verify the pairing.";
        primary = PPActionVerify; primaryTitle = @"Verify with LocalDevVPN";
        secondary = PPActionExport; secondaryTitle = @"Export Pairing File";
    } else if ([phase isEqualToString:@"stopped"]) {
        state = @"stopped";
        symbol = @"stop.circle";
        color = UIColor.systemGrayColor;
        title = @"Pairing Stopped";
        message = @"Start again when you’re ready.";
        primary = PPActionStart; primaryTitle = @"Start Pairing";
    } else {
        state = @"ready";
        symbol = @"iphone.radiowaves.left.and.right";
        title = @"Pair This iPhone";
        message = @"Connect to Wi‑Fi, then create a pairing file for StikDebug.";
        primary = PPActionStart; primaryTitle = @"Start Pairing";
    }

    NSString *code = hero == PPHeroCode ? [self formattedPIN] : @"";
    NSArray *buttons = @[@(primary), primaryTitle, @(secondary), secondaryTitle];
    NSArray *signature = @[state, @(hero), symbol, title, message, footnote, code, @(self.copiedPIN), buttons];
    if ([signature isEqualToArray:self.rendered]) return;
    BOOL structural = self.renderedState && (![state isEqualToString:self.renderedState] || ![buttons isEqualToArray:self.renderedButtons]);
    BOOL announce = self.renderedState && ![state isEqualToString:self.renderedState];
    self.rendered = signature;
    self.renderedState = state;
    self.renderedButtons = buttons;

    void (^apply)(void) = ^{
        self.symbolView.hidden = hero != PPHeroSymbol;
        self.symbolView.image = symbol.length ? [UIImage systemImageNamed:symbol] : nil;
        self.symbolView.tintColor = color;
        if (hero == PPHeroSpinner) [self.spinner startAnimating];
        else [self.spinner stopAnimating];
        self.codeLabel.hidden = hero != PPHeroCode;
        self.codeLabel.text = code;
        self.codeLabel.accessibilityLabel = code.length ? [NSString stringWithFormat:@"Pairing code %@", [self spokenPIN]] : nil;
        self.headlineLabel.text = title;
        self.messageLabel.text = message;
        self.messageLabel.hidden = message.length == 0;
        UIButtonConfiguration *copyConfig = self.codeCopyButton.configuration;
        copyConfig.title = self.copiedPIN ? @"Copied" : @"Copy Code";
        copyConfig.image = [UIImage systemImageNamed:self.copiedPIN ? @"checkmark" : @"doc.on.doc"];
        self.codeCopyButton.configuration = copyConfig;
        self.codeCopyButton.hidden = hero != PPHeroCode;
        self.footnoteLabel.text = footnote;
        self.footnoteLabel.hidden = footnote.length == 0;
        [self setButton:self.primaryButton action:primary title:primaryTitle];
        [self setButton:self.secondaryButton action:secondary title:secondaryTitle];
        [self.view layoutIfNeeded];
    };
    if (structural && self.view.window) {
        [UIView transitionWithView:self.view duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve|UIViewAnimationOptionAllowUserInteraction animations:apply completion:nil];
    } else {
        apply();
    }
    if (announce && self.view.window) UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self.headlineLabel);
}

- (void)setButton:(UIButton *)button action:(PPAction)action title:(NSString *)title {
    button.tag = action;
    button.hidden = action == PPActionNone;
    UIButtonConfiguration *config = button.configuration;
    config.title = title;
    button.configuration = config;
}

- (void)buttonTapped:(UIButton *)sender {
    switch ((PPAction)sender.tag) {
        case PPActionStart: [self startPairing]; break;
        case PPActionStop: [self stopPairing]; break;
        case PPActionVerify: [self verifyPairing]; break;
        case PPActionExport: [self exportPairingFrom:sender]; break;
        case PPActionOpenSettings:
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
            break;
        case PPActionNone: break;
    }
}

- (void)copyPIN {
    if (!self.lastPIN.length || self.codeLabel.hidden) return;
    UIPasteboard.generalPasteboard.string = self.lastPIN;
    self.copiedPIN = YES;
    [self refresh];
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
        self.problem = PPProblemUnsupportedOS;
        [self refresh];
        return;
    }
    [self.service stop];
    self.service = nil;
    self.lastPhase = nil;
    self.lastMessage = nil;
    self.lastPIN = nil;
    self.problem = PPProblemNone;
    self.published = NO;
    self.verifyRequested = NO;
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
    self.published = YES;
    [self refresh];
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    if (sender != self.service) return;
    NSString *message = [NSString stringWithFormat:@"Bonjour publication failed: %@. Check Settings → Apps → PhonePair → Local Network, then retry.", errorDict];
    [self appendLog:message];
    pp_stop();
    [sender stop];
    self.service = nil;
    self.problem = PPProblemLocalNetwork;
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
    self.verifyRequested = YES;
    self.verified = NO;
    self.exported = NO;
    self.problem = PPProblemNone;
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
    // Reset after polling: the app still reports the background state here, so polling first would bring the countdown back.
    self.backgroundNote = PPBackgroundHint;
    [self refresh];
}

- (void)exportPairingFrom:(UIView *)sourceView {
    NSString *source = [self.directory stringByAppendingPathComponent:@"pairingFile.plist"];
    NSURL *target = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"PhonePair-remote-pairing.plist"]];
    NSError *error;
    NSData *data = [NSData dataWithContentsOfFile:source options:0 error:&error];
    if (!data || ![data writeToURL:target options:NSDataWritingAtomic|NSDataWritingFileProtectionComplete error:&error]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn’t Export" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[target] applicationActivities:nil];
    share.popoverPresentationController.sourceView = sourceView ?: self.view;
    share.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *returnedItems, NSError *activityError) {
        if (!completed) return;
        self.exported = YES;
        self.problem = PPProblemNone;
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
    self.window.tintColor = PPTint();
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
