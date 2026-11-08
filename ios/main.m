#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import "PhonePairCore.h"

typedef NS_ENUM(NSInteger, PPAction) {
    PPActionNone = -1,
    PPActionStart,
    PPActionStop,
    PPActionVerify,
    PPActionExport,
};

static NSString *const PPBackgroundHint = @"Pair promptly: iOS gives PhonePair limited time while Settings is open.";

@interface PhonePairController : UIViewController <NSNetServiceDelegate, UNUserNotificationCenterDelegate>
// Status
@property(nonatomic, strong) UIImageView *statusIcon;
@property(nonatomic, strong) UIActivityIndicatorView *statusSpinner;
@property(nonatomic, strong) UILabel *statusTitleLabel;
@property(nonatomic, strong) UILabel *statusLabel;
// Pairing code
@property(nonatomic, strong) UIView *pinCard;
@property(nonatomic, strong) NSArray<UILabel *> *pinDigits;
@property(nonatomic, strong) UILabel *pinCaption;
@property(nonatomic, strong) UILabel *backgroundLabel;
// Steps
@property(nonatomic, strong) NSArray<UIView *> *stepCircles;
@property(nonatomic, strong) NSArray<UILabel *> *stepNumbers;
@property(nonatomic, strong) NSArray<UIImageView *> *stepChecks;
@property(nonatomic, strong) NSArray<UILabel *> *stepTitles;
// Actions
@property(nonatomic, strong) UIButton *primaryButton;
@property(nonatomic, strong) UIStackView *secondaryRow;
@property(nonatomic, strong) UIButton *restartButton;
@property(nonatomic, strong) UIButton *verifyButton;
@property(nonatomic, strong) UIButton *exportButton;
// Diagnostics
@property(nonatomic, strong) UIButton *diagnosticsToggle;
@property(nonatomic, strong) UIView *diagnosticsBody;
@property(nonatomic, strong) UITextView *logView;
// State
@property(nonatomic, strong) NSNetService *service;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, copy) NSString *lastPhase;
@property(nonatomic, copy) NSString *lastMessage;
@property(nonatomic, copy) NSString *lastPIN;
@property(nonatomic, strong) NSMutableString *diagnostics;
@property(nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL verified;
@property(nonatomic) BOOL exported;
@property(nonatomic) PPAction primaryAction;
@property(nonatomic) NSInteger currentStep;
@end

@implementation PhonePairController

#pragma mark - View helpers

- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.text = text;
    label.textColor = color;
    label.numberOfLines = 0;
    UITraitCollection *defaultSize = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryLarge];
    CGFloat size = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style compatibleWithTraitCollection:defaultSize].pointSize;
    label.font = [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]];
    label.adjustsFontForContentSizeCategory = YES;
    return label;
}

- (UIView *)cardWithContent:(UIStackView **)content {
    UIView *card = [UIView new];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 18;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
    ]];
    *content = stack;
    return card;
}

- (UIImage *)symbol:(NSString *)name size:(CGFloat)size weight:(UIImageSymbolWeight)weight {
    return [UIImage systemImageNamed:name withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:size weight:weight]];
}

- (UIButtonConfiguration *)configurationForTitle:(NSString *)title symbol:(NSString *)symbol style:(NSInteger)style color:(UIColor *)color {
    // style: 0 = filled, 1 = tinted, 2 = gray
    UIButtonConfiguration *config = style == 0 ? UIButtonConfiguration.filledButtonConfiguration
        : style == 1 ? UIButtonConfiguration.tintedButtonConfiguration : UIButtonConfiguration.grayButtonConfiguration;
    config.title = title;
    config.image = [self symbol:symbol size:15 weight:UIImageSymbolWeightSemibold];
    config.imagePadding = 8;
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    config.contentInsets = style == 0 ? NSDirectionalEdgeInsetsMake(16, 16, 16, 16) : NSDirectionalEdgeInsetsMake(12, 12, 12, 12);
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *updated = attributes.mutableCopy;
        updated[NSFontAttributeName] = [UIFont systemFontOfSize:style == 0 ? 17 : 15 weight:UIFontWeightSemibold];
        return updated;
    };
    if (color) {
        if (style == 0) config.baseBackgroundColor = color;
        else config.baseForegroundColor = color;
    }
    return config;
}

- (UIButton *)button:(UIButtonConfiguration *)config action:(SEL)action {
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark - Layout

- (UIView *)headerView {
    UIView *tile = [UIView new];
    tile.backgroundColor = self.view.tintColor;
    tile.layer.cornerRadius = 15;
    tile.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageView *glyph = [[UIImageView alloc] initWithImage:[self symbol:@"iphone.radiowaves.left.and.right" size:26 weight:UIImageSymbolWeightSemibold]];
    glyph.tintColor = UIColor.whiteColor;
    glyph.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:glyph];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [tile.widthAnchor constraintEqualToConstant:60],
        [tile.heightAnchor constraintEqualToConstant:60],
        [glyph.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [glyph.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
    ]];

    UILabel *title = [self label:@"PhonePair" style:UIFontTextStyleLargeTitle weight:UIFontWeightBold color:UIColor.labelColor];
    UILabel *subtitle = [self label:@"Create a StikDebug pairing file right on this iPhone." style:UIFontTextStyleSubheadline weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];

    UILabel *badge = [self label:@"EXPERIMENTAL · iOS 27" style:UIFontTextStyleCaption2 weight:UIFontWeightBold color:UIColor.systemOrangeColor];
    UIView *pill = [UIView new];
    pill.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.15];
    pill.layer.cornerRadius = 9;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [pill addSubview:badge];
    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor constraintEqualToAnchor:pill.topAnchor constant:3],
        [badge.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-3],
        [badge.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:8],
        [badge.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-8],
    ]];
    UIStackView *pillRow = [[UIStackView alloc] initWithArrangedSubviews:@[pill, [UIView new]]];

    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[pillRow, title, subtitle]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;
    [text setCustomSpacing:6 afterView:pillRow];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[tile, text]];
    row.spacing = 16;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (UIView *)statusCard {
    UIStackView *content;
    UIView *card = [self cardWithContent:&content];

    UIView *iconBox = [UIView new];
    iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusIcon = [UIImageView new];
    self.statusIcon.contentMode = UIViewContentModeCenter;
    self.statusIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.statusSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    [iconBox addSubview:self.statusIcon];
    [iconBox addSubview:self.statusSpinner];
    [NSLayoutConstraint activateConstraints:@[
        [iconBox.widthAnchor constraintEqualToConstant:30],
        [iconBox.heightAnchor constraintEqualToConstant:30],
        [self.statusIcon.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor],
        [self.statusIcon.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
        [self.statusSpinner.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor],
        [self.statusSpinner.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
    ]];

    self.statusTitleLabel = [self label:@"Ready" style:UIFontTextStyleHeadline weight:UIFontWeightSemibold color:UIColor.labelColor];
    self.statusLabel = [self label:@"This creates a fresh identity; it does not import your existing pairing file." style:UIFontTextStyleSubheadline weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusTitleLabel, self.statusLabel]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 3;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[iconBox, text]];
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentTop;
    [content addArrangedSubview:row];
    return card;
}

- (UIView *)pinCardView {
    UIStackView *content;
    UIView *card = [self cardWithContent:&content];
    content.spacing = 14;

    [content addArrangedSubview:[self label:@"PAIRING CODE" style:UIFontTextStyleFootnote weight:UIFontWeightSemibold color:UIColor.secondaryLabelColor]];

    NSMutableArray<UILabel *> *digits = [NSMutableArray new];
    UIStackView *digitRow = [UIStackView new];
    digitRow.distribution = UIStackViewDistributionFillEqually;
    digitRow.spacing = 8;
    for (NSInteger i = 0; i < 6; i++) {
        UILabel *digit = [UILabel new];
        digit.font = [UIFont monospacedDigitSystemFontOfSize:30 weight:UIFontWeightSemibold];
        digit.textAlignment = NSTextAlignmentCenter;
        digit.backgroundColor = UIColor.tertiarySystemFillColor;
        digit.layer.cornerRadius = 12;
        digit.layer.cornerCurve = kCACornerCurveContinuous;
        digit.clipsToBounds = YES;
        digit.isAccessibilityElement = NO;
        [digit.heightAnchor constraintEqualToConstant:60].active = YES;
        [digits addObject:digit];
        [digitRow addArrangedSubview:digit];
    }
    self.pinDigits = digits;
    digitRow.isAccessibilityElement = YES;
    digitRow.accessibilityTraits = UIAccessibilityTraitStaticText;
    [content addArrangedSubview:digitRow];

    self.pinCaption = [self label:@"" style:UIFontTextStyleFootnote weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    self.pinCaption.textAlignment = NSTextAlignmentCenter;
    [content addArrangedSubview:self.pinCaption];

    self.backgroundLabel = [self label:PPBackgroundHint style:UIFontTextStyleFootnote weight:UIFontWeightMedium color:UIColor.systemOrangeColor];
    self.backgroundLabel.textAlignment = NSTextAlignmentCenter;
    [content addArrangedSubview:self.backgroundLabel];

    [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyPIN)]];
    return card;
}

- (UIView *)stepsCard {
    UIStackView *content;
    UIView *card = [self cardWithContent:&content];
    content.spacing = 16;
    [content addArrangedSubview:[self label:@"How it works" style:UIFontTextStyleHeadline weight:UIFontWeightSemibold color:UIColor.labelColor]];

    NSArray<NSArray<NSString *> *> *steps = @[
        @[@"Start pairing", @"Join Wi-Fi, tap Start, and allow Local Network and Notifications."],
        @[@"Choose PhonePair in Settings", @"Settings → Privacy & Security → Developer Mode, then select “Pair with PhonePair on this iPhone”."],
        @[@"Enter the code", @"Type the six-digit code from the notification. Switch back here if you need to see it again."],
        @[@"Verify", @"Connect LocalDevVPN, return here, and tap Verify."],
        @[@"Export to StikDebug", @"Save the pairing file and import it in StikDebug."],
    ];
    NSMutableArray *circles = [NSMutableArray new], *numbers = [NSMutableArray new], *checks = [NSMutableArray new], *titles = [NSMutableArray new];
    [steps enumerateObjectsUsingBlock:^(NSArray<NSString *> *step, NSUInteger index, BOOL *stop) {
        UIView *circle = [UIView new];
        circle.layer.cornerRadius = 14;
        circle.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *number = [UILabel new];
        number.text = [NSString stringWithFormat:@"%lu", (unsigned long)index + 1];
        number.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightBold];
        number.translatesAutoresizingMaskIntoConstraints = NO;
        UIImageView *check = [[UIImageView alloc] initWithImage:[self symbol:@"checkmark" size:13 weight:UIImageSymbolWeightBold]];
        check.tintColor = UIColor.whiteColor;
        check.translatesAutoresizingMaskIntoConstraints = NO;
        [circle addSubview:number];
        [circle addSubview:check];
        [NSLayoutConstraint activateConstraints:@[
            [circle.widthAnchor constraintEqualToConstant:28],
            [circle.heightAnchor constraintEqualToConstant:28],
            [number.centerXAnchor constraintEqualToAnchor:circle.centerXAnchor],
            [number.centerYAnchor constraintEqualToAnchor:circle.centerYAnchor],
            [check.centerXAnchor constraintEqualToAnchor:circle.centerXAnchor],
            [check.centerYAnchor constraintEqualToAnchor:circle.centerYAnchor],
        ]];

        UILabel *title = [self label:step[0] style:UIFontTextStyleBody weight:UIFontWeightSemibold color:UIColor.labelColor];
        UILabel *detail = [self label:step[1] style:UIFontTextStyleFootnote weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
        UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[title, detail]];
        text.axis = UILayoutConstraintAxisVertical;
        text.spacing = 2;

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[circle, text]];
        row.spacing = 12;
        row.alignment = UIStackViewAlignmentTop;
        row.isAccessibilityElement = YES;
        row.accessibilityLabel = [NSString stringWithFormat:@"Step %lu: %@. %@", (unsigned long)index + 1, step[0], step[1]];
        [content addArrangedSubview:row];

        [circles addObject:circle];
        [numbers addObject:number];
        [checks addObject:check];
        [titles addObject:title];
    }];
    self.stepCircles = circles;
    self.stepNumbers = numbers;
    self.stepChecks = checks;
    self.stepTitles = titles;
    self.currentStep = -1;
    return card;
}

- (UIView *)actionsView {
    self.primaryAction = PPActionNone;
    self.primaryButton = [self button:UIButtonConfiguration.filledButtonConfiguration action:@selector(primaryTapped:)];
    self.restartButton = [self button:[self configurationForTitle:@"Start over" symbol:@"arrow.clockwise" style:1 color:nil] action:@selector(startPairing)];
    self.verifyButton = [self button:[self configurationForTitle:@"Verify again" symbol:@"checkmark.shield" style:1 color:nil] action:@selector(verifyPairing)];
    self.exportButton = [self button:[self configurationForTitle:@"Export" symbol:@"square.and.arrow.up" style:1 color:nil] action:@selector(exportPairing:)];
    self.secondaryRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.restartButton, self.verifyButton, self.exportButton]];
    self.secondaryRow.spacing = 10;
    self.secondaryRow.distribution = UIStackViewDistributionFillEqually;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.primaryButton, self.secondaryRow]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    return stack;
}

- (UIView *)diagnosticsCard {
    UIStackView *content;
    UIView *card = [self cardWithContent:&content];
    content.spacing = 12;

    UIButtonConfiguration *toggle = UIButtonConfiguration.plainButtonConfiguration;
    toggle.contentInsets = NSDirectionalEdgeInsetsZero;
    toggle.baseForegroundColor = UIColor.labelColor;
    self.diagnosticsToggle = [self button:toggle action:@selector(toggleDiagnostics)];
    self.diagnosticsToggle.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    [content addArrangedSubview:self.diagnosticsToggle];

    self.logView = [UITextView new];
    self.logView.editable = NO;
    self.logView.scrollEnabled = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logView.textColor = UIColor.secondaryLabelColor;
    self.logView.backgroundColor = UIColor.tertiarySystemFillColor;
    self.logView.layer.cornerRadius = 12;
    self.logView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    self.logView.text = self.diagnostics;
    UIButton *share = [self button:[self configurationForTitle:@"Share diagnostics" symbol:@"square.and.arrow.up" style:2 color:nil] action:@selector(shareDiagnostics)];
    UIStackView *body = [[UIStackView alloc] initWithArrangedSubviews:@[self.logView, share]];
    body.axis = UILayoutConstraintAxisVertical;
    body.spacing = 10;
    body.hidden = YES;
    self.diagnosticsBody = body;
    [content addArrangedSubview:body];
    [self updateDiagnosticsToggle];
    return card;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.backgroundTask = UIBackgroundTaskInvalid;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
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
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    NSLayoutConstraint *fullWidth = [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40];
    fullWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [stack.centerXAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.centerXAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:560],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:scroll.safeAreaLayoutGuide.leadingAnchor constant:20],
        fullWidth,
    ]];

    UIView *header = [self headerView];
    [stack addArrangedSubview:header];
    [stack setCustomSpacing:24 afterView:header];
    [stack addArrangedSubview:[self statusCard]];
    self.pinCard = [self pinCardView];
    [stack addArrangedSubview:self.pinCard];
    [stack addArrangedSubview:[self actionsView]];
    [stack addArrangedSubview:[self stepsCard]];
    [stack addArrangedSubview:[self diagnosticsCard]];

    UILabel *footer = [self label:@"Your existing StikDebug pairing is not changed by this app. Pairing keys stay on your phone unless you choose Export." style:UIFontTextStyleFootnote weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    footer.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:footer];

    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(enterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(enterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    [self poll];
}

#pragma mark - UI state

- (void)showPIN:(NSString *)pin {
    for (NSUInteger i = 0; i < self.pinDigits.count; i++) {
        UILabel *digit = self.pinDigits[i];
        BOOL has = i < pin.length;
        digit.text = has ? [pin substringWithRange:NSMakeRange(i, 1)] : @"–";
        digit.textColor = has ? UIColor.labelColor : UIColor.tertiaryLabelColor;
    }
    UIView *row = self.pinDigits.firstObject.superview;
    row.accessibilityLabel = pin.length ? [NSString stringWithFormat:@"Pairing code %@", pin] : @"No active pairing code";
    self.pinCaption.text = pin.length
        ? @"Enter this code in Settings. It was also sent as a notification. Tap to copy."
        : @"The code appears after you select PhonePair in Developer Mode settings.";
    if (pin.length) {
        for (UILabel *digit in self.pinDigits) {
            digit.transform = CGAffineTransformMakeScale(0.85, 0.85);
        }
        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0 options:0 animations:^{
            for (UILabel *digit in self.pinDigits) digit.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

- (void)copyPIN {
    if (!self.lastPIN.length || !self.running) return;
    UIPasteboard.generalPasteboard.string = self.lastPIN;
    [[UIImpactFeedbackGenerator.alloc initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    self.pinCaption.text = @"Copied to clipboard.";
}

- (void)updateStatusForPhase:(NSString *)phase hasFile:(BOOL)hasFile {
    NSString *title, *symbol;
    UIColor *color;
    BOOL busy = NO;
    if ([phase isEqualToString:@"listening"]) {
        title = @"Waiting for Settings"; busy = YES;
    } else if ([phase isEqualToString:@"pin"]) {
        title = @"Enter the code in Settings"; symbol = @"number.circle.fill"; color = UIColor.systemOrangeColor;
    } else if ([phase isEqualToString:@"paired"]) {
        title = @"Paired, verify next"; symbol = @"checkmark.circle.fill"; color = self.view.tintColor;
    } else if ([phase isEqualToString:@"verifying"]) {
        title = @"Verifying…"; busy = YES;
    } else if ([phase isEqualToString:@"verified"]) {
        title = @"Verified, ready to export"; symbol = @"checkmark.seal.fill"; color = UIColor.systemGreenColor;
    } else if ([phase isEqualToString:@"error"]) {
        title = @"Something went wrong"; symbol = @"exclamationmark.triangle.fill"; color = UIColor.systemRedColor;
    } else if ([phase isEqualToString:@"stopped"]) {
        title = @"Stopped"; symbol = @"stop.circle.fill"; color = UIColor.systemGrayColor;
    } else if (hasFile) {
        title = @"Pairing file ready"; symbol = @"doc.badge.checkmark"; color = self.view.tintColor;
    } else {
        title = @"Ready to pair"; symbol = @"bolt.horizontal.circle.fill"; color = self.view.tintColor;
    }
    if (self.exported) {
        title = @"Exported"; symbol = @"checkmark.seal.fill"; color = UIColor.systemGreenColor; busy = NO;
    }
    self.statusTitleLabel.text = title;
    if (busy) {
        self.statusIcon.hidden = YES;
        [self.statusSpinner startAnimating];
    } else {
        [self.statusSpinner stopAnimating];
        self.statusIcon.hidden = NO;
        self.statusIcon.image = [self symbol:symbol size:22 weight:UIImageSymbolWeightSemibold];
        self.statusIcon.tintColor = color;
    }
}

- (void)updateSteps:(NSInteger)current {
    if (current == self.currentStep) return;
    self.currentStep = current;
    [UIView animateWithDuration:0.25 animations:^{
        for (NSInteger i = 0; i < (NSInteger)self.stepCircles.count; i++) {
            BOOL done = i < current, active = i == current;
            self.stepCircles[i].backgroundColor = done ? UIColor.systemGreenColor : active ? self.view.tintColor : UIColor.tertiarySystemFillColor;
            self.stepChecks[i].hidden = !done;
            self.stepNumbers[i].hidden = done;
            self.stepNumbers[i].textColor = active ? UIColor.whiteColor : UIColor.secondaryLabelColor;
            self.stepTitles[i].textColor = (done || active) ? UIColor.labelColor : UIColor.secondaryLabelColor;
        }
    }];
}

- (void)setPrimary:(PPAction)action {
    if (action == self.primaryAction) return;
    self.primaryAction = action;
    UIButtonConfiguration *config;
    switch (action) {
        case PPActionStop:
            config = [self configurationForTitle:@"Stop" symbol:@"stop.fill" style:2 color:UIColor.systemRedColor];
            config.contentInsets = NSDirectionalEdgeInsetsMake(16, 16, 16, 16);
            break;
        case PPActionVerify:
            config = [self configurationForTitle:@"Verify with LocalDevVPN" symbol:@"checkmark.shield.fill" style:0 color:nil];
            break;
        case PPActionExport:
            config = [self configurationForTitle:@"Export pairing file" symbol:@"square.and.arrow.up" style:0 color:UIColor.systemGreenColor];
            break;
        default:
            config = [self configurationForTitle:@"Start pairing" symbol:@"play.fill" style:0 color:nil];
            break;
    }
    self.primaryButton.configuration = config;
}

- (void)primaryTapped:(UIButton *)sender {
    switch (self.primaryAction) {
        case PPActionStop: [self stopPairing]; break;
        case PPActionVerify: [self verifyPairing]; break;
        case PPActionExport: [self exportPairing:sender]; break;
        default: [self startPairing]; break;
    }
}

- (void)updateDiagnosticsToggle {
    UIButtonConfiguration *config = self.diagnosticsToggle.configuration;
    NSDictionary *attributes = @{NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]};
    config.attributedTitle = [[NSAttributedString alloc] initWithString:@"Diagnostics" attributes:attributes];
    config.image = [self symbol:self.diagnosticsBody.hidden ? @"chevron.right" : @"chevron.down" size:13 weight:UIImageSymbolWeightSemibold];
    config.imagePlacement = NSDirectionalRectEdgeTrailing;
    self.diagnosticsToggle.configuration = config;
}

- (void)toggleDiagnostics {
    [UIView animateWithDuration:0.25 animations:^{
        self.diagnosticsBody.hidden = !self.diagnosticsBody.hidden;
        [self.view layoutIfNeeded];
    }];
    [self updateDiagnosticsToggle];
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
    self.logView.text = self.diagnostics;
    NSArray<NSURL *> *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    [self.diagnostics writeToURL:[documents.firstObject URLByAppendingPathComponent:@"PhonePair-diagnostics.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)startPairing {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27) {
        self.statusTitleLabel.text = @"iOS 27 required";
        self.statusLabel.text = @"This experiment requires iOS 27 or newer.";
        return;
    }
    [self.service stop];
    self.service = nil;
    self.lastPhase = nil;
    self.lastMessage = nil;
    self.lastPIN = nil;
    self.verified = NO;
    self.exported = NO;
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
    if ([self.lastPhase isEqualToString:@"listening"]) self.statusLabel.text = @"Open Settings → Privacy & Security → Developer Mode and select “Pair with PhonePair on this iPhone”.";
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
    BOOL hasFile = [NSFileManager.defaultManager fileExistsAtPath:[self.directory stringByAppendingPathComponent:@"pairingFile.plist"]];
    if (changed) {
        if (self.lastPhase && ![phase isEqualToString:self.lastPhase]) {
            UINotificationFeedbackGenerator *haptics = [UINotificationFeedbackGenerator new];
            if ([phase isEqualToString:@"error"]) [haptics notificationOccurred:UINotificationFeedbackTypeError];
            else if ([phase isEqualToString:@"paired"] || [phase isEqualToString:@"verified"]) [haptics notificationOccurred:UINotificationFeedbackTypeSuccess];
            else if ([phase isEqualToString:@"pin"]) [haptics notificationOccurred:UINotificationFeedbackTypeWarning];
        }
        if ([phase isEqualToString:@"verified"]) self.verified = YES;
        self.statusLabel.text = message;
        [self appendLog:[NSString stringWithFormat:@"%@: %@", phase, message]];
        self.lastPhase = phase;
        self.lastMessage = message;
    }
    NSString *pin = [snapshot[@"pin"] isKindOfClass:NSString.class] ? snapshot[@"pin"] : nil;
    if (pin.length && ![pin isEqualToString:self.lastPIN]) {
        self.lastPIN = pin;
        [self showPIN:pin];
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
    BOOL pairingActive = running && ([phase isEqualToString:@"listening"] || [phase isEqualToString:@"pin"]);
    if (pairingActive != !self.pinCard.hidden) {
        if (pairingActive) [self showPIN:self.lastPIN];
        [UIView animateWithDuration:0.25 animations:^{
            self.pinCard.hidden = !pairingActive;
            self.pinCard.alpha = pairingActive ? 1 : 0;
        }];
    }
    self.running = running;

    [self updateStatusForPhase:phase hasFile:hasFile];

    NSInteger step;
    if (self.exported) step = 5;
    else if (self.verified) step = 4;
    else if ([phase isEqualToString:@"verifying"]) step = 3;
    else if ([phase isEqualToString:@"pin"]) step = 2;
    else if (running) step = 1;
    else if (hasFile) step = 3;
    else step = 0;
    [self updateSteps:step];

    PPAction primary = running ? PPActionStop : !hasFile ? PPActionStart : self.verified ? PPActionExport : PPActionVerify;
    [self setPrimary:primary];
    BOOL showSecondary = !running && hasFile;
    if (self.secondaryRow.hidden == showSecondary) self.secondaryRow.hidden = !showSecondary;
    self.verifyButton.hidden = primary != PPActionExport;
    self.exportButton.hidden = primary != PPActionVerify;

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
    self.verified = NO;
    self.exported = NO;
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
    self.backgroundLabel.text = PPBackgroundHint;
}

- (void)shareItems:(NSArray *)items from:(UIView *)source completion:(void (^)(BOOL completed))completion {
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    share.popoverPresentationController.sourceView = source ?: self.view;
    share.popoverPresentationController.sourceRect = source ? source.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    if (completion) {
        share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *returnedItems, NSError *error) {
            completion(completed);
        };
    }
    [self presentViewController:share animated:YES completion:nil];
}

- (void)exportPairing:(UIView *)sender {
    NSString *source = [self.directory stringByAppendingPathComponent:@"pairingFile.plist"];
    NSURL *target = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"PhonePair-remote-pairing.plist"]];
    NSError *error;
    NSData *data = [NSData dataWithContentsOfFile:source options:0 error:&error];
    if (!data || ![data writeToURL:target options:NSDataWritingAtomic|NSDataWritingFileProtectionComplete error:&error]) {
        self.statusLabel.text = [NSString stringWithFormat:@"Export failed: %@", error.localizedDescription];
        return;
    }
    [self shareItems:@[target] from:sender completion:^(BOOL completed) {
        if (!completed) return;
        self.exported = YES;
        [self appendLog:@"Pairing file exported. Import it in StikDebug."];
        self.statusLabel.text = @"Import the file in StikDebug and try enabling JIT.";
        [self poll];
    }];
}

- (void)shareDiagnostics {
    [self shareItems:@[self.diagnostics.copy] from:self.logView completion:nil];
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
