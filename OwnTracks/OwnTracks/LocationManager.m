//
//  LocationManager.m
//  OwnTracks
//
//  Created by Christoph Krey on 21.10.14.
//  Copyright © 2014-2026  OwnTracks. All rights reserved.
//

#import "LocationManager.h"
#import "OwnTracksAppDelegate.h"
#import "CoreData.h"
#import "OwnTracksLog.h"
#import "OwnTracks-Swift.h"

@interface LocationManager()
@property (strong, nonatomic) CLLocationManager *manager;
@property (strong, nonatomic) CLLocation *lastUsedLocation;
@property (strong, nonatomic) CLLocation *lastLocationWithMovement;
@property (strong, nonatomic) NSTimer *activityTimer;
// 改造2: minTimeごとに数秒だけBestへ上げて1点取る
@property (strong, nonatomic) NSTimer *boostTimer;
@property (strong, nonatomic) NSDate *boostStart;
@property (strong, nonatomic) CLLocation *boostBest;
@property (strong, nonatomic) NSMutableSet *pendingRegionEvents;
// 改造mod9: CLMonitor（起動のたびに同じ名前で作る。準備ができるまでの操作は積んでおく）
@property (strong, nonatomic) CLMonitor *monitor;
@property (strong, nonatomic) CLServiceSession *serviceSession;
@property (strong, nonatomic) NSMutableArray *pendingMonitorOps;
@property (strong, nonatomic) NSMutableDictionary<NSString *, OTRegion *> *regions;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSNumber *> *knownStates;
@property (strong, nonatomic) NSMutableSet<NSString *> *initialPending;
// mod12: 静止の判定に使う直近の精度の良い点、mode 1で起こされたときの取得、判定に使った点
@property (strong, nonatomic) NSMutableArray<CLLocation *> *recentFixes;
@property (nonatomic) BOOL wakeChecking;
@property (copy, nonatomic) NSString *wakeReason;
@property (nonatomic) UIBackgroundTaskIdentifier wakeTask;
@property (strong, nonatomic) CLLocation *judgedLocation;
// mod13: 円の外の点が続いた数（2点で「出」）、最後に起こされた判定の終わり、精度の悪い取得が続いた数
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSNumber *> *exitStreak;
@property (strong, nonatomic) NSMutableDictionary<NSString *, CLLocation *> *exitFirst;
// mod18: 円の中の点が続いた数（2点で「入」）と1点目
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSNumber *> *enterStreak;
@property (strong, nonatomic) NSMutableDictionary<NSString *, CLLocation *> *enterFirst;
@property (strong, nonatomic) NSDate *lastWakeCheckEnd;
@property (nonatomic) NSInteger badFixStreak;
@property (nonatomic) BOOL boostRetried;
// mod17: 起こされた確認で、場所の円の外だった1点目（2点続けて外ならMove）
@property (strong, nonatomic) CLLocation *wakeFirst;
// mod17: iOSの出入りの知らせを、1点測ってから送る（[OTRegion, @(enter)]の並び）
@property (strong, nonatomic) NSMutableArray<NSArray *> *measureEvents;
@property (nonatomic) UIBackgroundTaskIdentifier measureTask;
- (void)holdDownExpired:(NSTimer *)timer;

@property (strong, nonatomic) NSMutableDictionary *insideCircularRegions;
@property (strong, nonatomic) NSTimer *backgroundTimer;
@property (strong, nonatomic) NSUserDefaults *sharedUserDefaults;

@property (nonatomic) CLAuthorizationStatus locationManagerAuthorizationStatus;

@property (nonatomic) CMAuthorizationStatus altimeterAuthorizationStatus;
@property (nonatomic) BOOL altimeterIsRelativeAltitudeAvailable;
@property (strong, nonatomic) CMAltimeter *altimeter;
@property (strong, nonatomic) CMAltitudeData *altitudeData;

@property (nonatomic) CMAuthorizationStatus motionActivityManagerAuthorizationStatus;
@property (nonatomic) BOOL motionActivityManagerIsActivityAvailable;
@property (strong, nonatomic) CMMotionActivityManager *motionActivityManager;
@property (strong, nonatomic) CMMotionActivity *motionActivity;

@end

@interface PendingRegionEvent : NSObject
@property (strong, nonatomic) OTRegion *region;
@property (strong, nonatomic) NSTimer *holdDownTimer;

@end

#define BACKGROUND_STOP_AFTER 5.0 // seconds
#define ASSUME_NO_MOTION 0.05 // meters per second (0.05 m/sec is 180 m/hour)
// 改造1・2の値（設定画面には出さない）
#define LOW_DISTANCE_FILTER 50.0 // meters
#define BOOST_ACCURACY 20.0 // meters
#define BOOST_SECONDS 10.0 // seconds
#define STATIONARY_SECONDS 300.0 // mod12: 静止の判定に使う点の期間
#define STATIONARY_CENTER_SECONDS 240.0 // mod12: 静止の円の中心に使う点の期間
#define STATIONARY_MIN_POINTS 4 // mod12: 静止の判定に要る点の数
#define STATIONARY_SPREAD 50.0 // mod12: 静止とみなす点の散らばり（m）
#define FOLLOW_MIN_RADIUS 20.0 // mod12: 追いかけの円の最小の半径
#define MONITOR_NAME @"ot" // 改造mod9: CLMonitorの名前

@implementation OTRegion

+ (OTRegion *)regionWithIdentifier:(NSString *)identifier
                            center:(CLLocationCoordinate2D)center
                            radius:(CLLocationDistance)radius {
    OTRegion *r = [[OTRegion alloc] init];
    r.identifier = identifier;
    r.center = center;
    r.radius = radius;
    return r;
}

- (BOOL)isFollow {
    return [self.identifier hasPrefix:@"+"];
}

@end

@implementation PendingRegionEvent

+ (PendingRegionEvent *)holdDown:(OTRegion *)region
for:(NSTimeInterval)interval
to:(id)to {
    PendingRegionEvent *p = [[PendingRegionEvent alloc] init];
    p.region = region;
    p.holdDownTimer = [NSTimer timerWithTimeInterval:interval
                                              target:to
                                            selector:@selector(holdDownExpired:)
                                            userInfo:p
                                             repeats:NO];
    [[NSRunLoop currentRunLoop] addTimer:p.holdDownTimer forMode:NSRunLoopCommonModes];
    return p;
}

@end

@implementation LocationManager
static LocationManager *theInstance = nil;

+ (LocationManager *)sharedInstance {
    if (theInstance == nil) {
        theInstance = [[LocationManager alloc] init];
    }
    return theInstance;
}

- (instancetype)init {
    self = [super init];
    
    self.manager = [[CLLocationManager alloc] init];
    self.manager.delegate = self;
    
    self.altimeter = [[CMAltimeter alloc] init];
    self.motionActivityManager = [[CMMotionActivityManager alloc] init];
    
    self.insideCircularRegions = [[NSMutableDictionary alloc] init];
    self.pendingMonitorOps = [[NSMutableArray alloc] init];
    self.regions = [[NSMutableDictionary alloc] init];
    self.knownStates = [[NSMutableDictionary alloc] init];
    self.initialPending = [[NSMutableSet alloc] init];
    self.recentFixes = [[NSMutableArray alloc] init];
    self.exitStreak = [[NSMutableDictionary alloc] init];
    self.exitFirst = [[NSMutableDictionary alloc] init];
    self.enterStreak = [[NSMutableDictionary alloc] init];
    self.enterFirst = [[NSMutableDictionary alloc] init];
    self.wakeTask = UIBackgroundTaskInvalid;
    self.measureTask = UIBackgroundTaskInvalid;
    self.measureEvents = [[NSMutableArray alloc] init];
    self.lastUsedLocation = [[CLLocation alloc] initWithLatitude:0 longitude:0];
    self.lastLocationWithMovement = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(0.0, 0.0)
                                                                  altitude:(0.0)
                                                        horizontalAccuracy:-1.0
                                                          verticalAccuracy:-1.0
                                                                 timestamp:[NSDate date]];
    self.pendingRegionEvents = [[NSMutableSet alloc] init];
    [self setupMonitor];

    [self authorize];
    
    [[NSNotificationCenter defaultCenter]
     addObserverForName:UIApplicationWillEnterForegroundNotification
     object:nil
     queue:nil
     usingBlock:^(NSNotification *note){
        OwnTracksLogDebug("[LocationManager] UIApplicationWillEnterForegroundNotification");
    }];
    [[NSNotificationCenter defaultCenter]
     addObserverForName:UIApplicationDidBecomeActiveNotification
     object:nil
     queue:nil
     usingBlock:^(NSNotification *note){
        OwnTracksLogDebug("[LocationManager] UIApplicationDidBecomeActiveNotification");
        [self wakeup];
    }];
    [[NSNotificationCenter defaultCenter]
     addObserverForName:UIApplicationWillResignActiveNotification
     object:nil
     queue:nil
     usingBlock:^(NSNotification *note){
        OwnTracksLogDebug("[LocationManager] UIApplicationWillResignActiveNotification");
        [self sleep];
    }];
    [[NSNotificationCenter defaultCenter]
     addObserverForName:UIApplicationWillTerminateNotification
     object:nil
     queue:nil
     usingBlock:^(NSNotification *note){
        OwnTracksLogDebug("[LocationManager] UIApplicationWillTerminateNotification");
        [self stop];
    }];
    
    self.sharedUserDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.org.owntracks.Owntracks"];
    [self.sharedUserDefaults addObserver:self forKeyPath:@"monitoringWithAuthKey"
                                 options:NSKeyValueObservingOptionNew
                                 context:nil];
    [self.sharedUserDefaults addObserver:self forKeyPath:@"sendNowWithAuthKey"
                                 options:NSKeyValueObservingOptionNew
                                 context:nil];
    [self.sharedUserDefaults addObserver:self forKeyPath:@"poiWithAuthKey"
                                 options:NSKeyValueObservingOptionNew
                                 context:nil];
    [self.sharedUserDefaults addObserver:self forKeyPath:@"tagWithAuthKey"
                                 options:NSKeyValueObservingOptionNew
                                 context:nil];

    return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    OwnTracksLogDebug("[LocationManager] observeValueForKeyPath %@", keyPath);

    if (![Settings theAllowIntentControlInMOC:CoreData.sharedInstance.mainMOC]) {
        [NavigationController alertWithTitle:
         NSLocalizedString(@"Intent Control",
                           @"Header of an alert message regarding intent control")
                            message:
         NSLocalizedString(@"Intent control not allowed",
                           @"content of an alert message regarding intent control")];
        OwnTracksLogError("[LocationManager] Intents not allowed: %{public}@", keyPath);
    } else {
        if ([keyPath isEqualToString:@"monitoringWithAuthKey"]) {
            NSUserDefaults *shared = object;
            NSDictionary *dict = [shared objectForKey:@"monitoringWithAuthKey"];
            NSString *intentAuthKey = dict[@"intentAuthKey"];
            NSNumber *monitoringNumber = dict[@"monitoring"];
            NSInteger monitoring = monitoringNumber != nil ? monitoringNumber.integerValue : 0;
            if (intentAuthKey == nil || ![intentAuthKey isEqualToString:[Settings theIntentAuthKey]]) {
                [NavigationController alertWithTitle:
                 NSLocalizedString(@"Intent Control",
                                   @"Header of an alert message regarding intent control")
                                             message:
                 NSLocalizedString(@"Wrong intent auth key",
                                   @"content of an alert message regarding intent auth key")];
                OwnTracksLogError("[LocationManager] Wrong Intent Auth Key");
            } else {
                if (monitoring != self.monitoring) {
                    self.monitoring = monitoring;
                    [[NSUserDefaults standardUserDefaults] setBool:FALSE forKey:@"downgraded"];
                    NSManagedObjectContext *moc = CoreData.sharedInstance.mainMOC;
                    [Settings setInt:(int)[LocationManager sharedInstance].monitoring
                              forKey:@"monitoring_preference" inMOC:moc];
                    [CoreData.sharedInstance sync:moc];
                }
            }
        } else if ([keyPath isEqualToString:@"sendNowWithAuthKey"]) {
            NSUserDefaults *shared = object;
            NSDictionary *dict = [shared objectForKey:@"sendNowWithAuthKey"];
            NSString *intentAuthKey = dict[@"intentAuthKey"];
            if (intentAuthKey == nil || ![intentAuthKey isEqualToString:[Settings theIntentAuthKey]]) {
                [NavigationController alertWithTitle:
                 NSLocalizedString(@"Intent Control",
                                   @"Header of an alert message regarding intent control")
                                             message:
                 NSLocalizedString(@"Wrong intent auth key",
                                   @"content of an alert message regarding intent auth key")];
                OwnTracksLogError("[LocationManager] Wrong Intent Auth Key");
            } else {
                OwnTracksAppDelegate *ad = (OwnTracksAppDelegate *)[UIApplication sharedApplication].delegate;
                [ad sendNow:self.location withPOI:nil withImage:nil withImageName:nil];
            }
        } else if ([keyPath isEqualToString:@"poiWithAuthKey"]) {
            NSUserDefaults *shared = object;
            NSDictionary *dict = [shared objectForKey:@"poiWithAuthKey"];
            NSString *intentAuthKey = dict[@"intentAuthKey"];
            NSString *poi = dict[@"poi"];
            if (intentAuthKey == nil || ![intentAuthKey isEqualToString:[Settings theIntentAuthKey]]) {
                [NavigationController alertWithTitle:
                 NSLocalizedString(@"Intent Control",
                                   @"Header of an alert message regarding intent control")
                                             message:
                 NSLocalizedString(@"Wrong intent auth key",
                                   @"content of an alert message regarding intent auth key")];
                OwnTracksLogError("[LocationManager] Wrong Intent Auth Key");
            } else {
                OwnTracksAppDelegate *ad = (OwnTracksAppDelegate *)[UIApplication sharedApplication].delegate;
                [ad sendNow:self.location withPOI:poi withImage:nil withImageName:nil];
            }
        } else if ([keyPath isEqualToString:@"tagWithAuthKey"]) {
            NSUserDefaults *shared = object;
            NSDictionary *dict = [shared objectForKey:@"tagWithAuthKey"];
            NSString *intentAuthKey = dict[@"intentAuthKey"];
            NSString *tag = dict[@"tag"];
            if (intentAuthKey == nil || ![intentAuthKey isEqualToString:[Settings theIntentAuthKey]]) {
                [NavigationController alertWithTitle:
                 NSLocalizedString(@"Intent Control",
                                   @"Header of an alert message regarding intent control")
                                             message:
                 NSLocalizedString(@"Wrong intent auth key",
                                   @"content of an alert message regarding intent auth key")];
                OwnTracksLogError("[LocationManager] Wrong Intent Auth Key");
            } else {
                if (tag && tag.length) {
                    [[NSUserDefaults standardUserDefaults] setObject:tag forKey:@"tag"];
                } else {
                    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"tag"];
                }
            }
        }
    }
}

- (void)start {
    OwnTracksLogDebug("[LocationManager] start");
    [self authorize];
    
    // 改造R1: 高度計（気圧p）は使わないので動かさない

    self.motionActivityManagerAuthorizationStatus = [CMMotionActivityManager authorizationStatus];
    self.motionActivityManagerIsActivityAvailable = [CMMotionActivityManager isActivityAvailable];
    OwnTracksLogDefault("[LocationManager] CMMotionActivityManager status=%ld, available=%d",
              (long)self.motionActivityManagerAuthorizationStatus,
              self.motionActivityManagerIsActivityAvailable);
    
    if (self.motionActivityManagerIsActivityAvailable &&
        (self.motionActivityManagerAuthorizationStatus == CMAuthorizationStatusNotDetermined ||
         self.motionActivityManagerAuthorizationStatus == CMAuthorizationStatusAuthorized)) {
        OwnTracksLogDebug("[LocationManager] startActivityUpdatesToQueue");
        [self.motionActivityManager startActivityUpdatesToQueue:[NSOperationQueue mainQueue]
                                                    withHandler:^(CMMotionActivity * _Nullable activity) {
            OwnTracksLogDebug("[LocationManager] activity %{public}@", activity);
            self.motionActivity = activity;
        }];
    }
}

- (void)wakeup {
    OwnTracksLogDebug("[LocationManager] wakeup");
    [self authorize];
    if (self.monitoring == LocationMonitoringMove) {
        [self.activityTimer invalidate];
        self.activityTimer = [NSTimer timerWithTimeInterval:self.minTime
                                                     target:self
                                                   selector:@selector(activityTimer:)
                                                   userInfo:Nil
                                                    repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:self.activityTimer
                                     forMode:NSRunLoopCommonModes];
    }
    [self refreshRegionStates];
    if (self.monitoring == LocationMonitoringSignificant) {
        [self.manager requestLocation];
    }
    [self startBackgroundTimer];
}

- (void)authorize {
    self.locationManagerAuthorizationStatus = self.manager.authorizationStatus;
    OwnTracksLogDebug("[LocationManager] authorizationStatus=%d",
                 self.locationManagerAuthorizationStatus);
    if (self.locationManagerAuthorizationStatus == kCLAuthorizationStatusNotDetermined) {
        [self.manager requestAlwaysAuthorization];
    }
}

- (void)sleep {
    OwnTracksLogDebug("[LocationManager] sleep");
    if (self.monitoring != LocationMonitoringMove) {
        [self.activityTimer invalidate];
    }
}

- (void)stop {
    OwnTracksLogDebug("[LocationManager] stop");
    
    if ([CMAltimeter isRelativeAltitudeAvailable]) {
        OwnTracksLogDebug("[LocationManager] stopRelativeAltitudeUpdates");
        [self.altimeter stopRelativeAltitudeUpdates];
    }
    
    if ([CMMotionActivityManager isActivityAvailable]) {
        OwnTracksLogDebug("[LocationManager] stopActivityUpdates");
        [self.motionActivityManager stopActivityUpdates];
    }
}

/*
 *
 * 改造mod9: CLMonitorによる範囲の監視
 *
 */
- (void)setupMonitor {
    __weak LocationManager *weakSelf = self;
    // 改造mod10: 背景でCLMonitorのイベントを受けるため、Alwaysのサービスセッションを起動のたび（背景の起動も）に作って持つ。
    // 無いとイベントにserviceSessionRequiredが付き、前面に出るまで届かない（Apple: Handling location updates in the background）
    if (!self.serviceSession) {
        self.serviceSession =
        [CLServiceSession sessionRequiringAuthorization:CLServiceSessionAuthorizationRequirementAlways];
        OwnTracksLogDefault("[LocationManager] service session always");
    }
    CLMonitorConfiguration *config =
    [CLMonitorConfiguration configWithMonitorName:MONITOR_NAME
                                            queue:dispatch_get_main_queue()
                                     eventHandler:^(CLMonitor *monitor, CLMonitoringEvent *event) {
        [weakSelf monitor:monitor event:event];
    }];
    [CLMonitor requestMonitorWithConfiguration:config completion:^(CLMonitor *monitor) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf monitorReady:monitor];
        });
    }];
}

- (void)monitorReady:(CLMonitor *)monitor {
    self.monitor = monitor;
    OwnTracksLogDefault("[LocationManager] monitor ready %lu",
                        (unsigned long)monitor.monitoredIdentifiers.count);
    // 保存済みの条件から範囲と状態を戻す（起動直後のinregionsを空にしない）
    for (NSString *identifier in monitor.monitoredIdentifiers) {
        [self regionForIdentifier:identifier monitor:monitor];
    }
    [self refreshRegionStates];
    [self migrateLegacyRegions];
    NSArray *ops = [self.pendingMonitorOps copy];
    [self.pendingMonitorOps removeAllObjects];
    for (void (^op)(CLMonitor *) in ops) {
        op(monitor);
    }
}

- (OTRegion *)regionForIdentifier:(NSString *)identifier monitor:(CLMonitor *)monitor {
    OTRegion *region = self.regions[identifier];
    if (!region) {
        CLMonitoringRecord *record = [monitor monitoringRecordForIdentifier:identifier];
        if ([record.condition isKindOfClass:[CLCircularGeographicCondition class]]) {
            CLCircularGeographicCondition *c = (CLCircularGeographicCondition *)record.condition;
            region = [OTRegion regionWithIdentifier:identifier center:c.center radius:c.radius];
            self.regions[identifier] = region;
        }
    }
    return region;
}

- (void)withMonitor:(void (^)(CLMonitor *monitor))op {
    if (self.monitor) {
        op(self.monitor);
    } else {
        [self.pendingMonitorOps addObject:[op copy]];
    }
}

// 旧API（CLLocationManagerのリージョン監視）で登録済みの範囲を、1回だけCLMonitorへ移す
- (void)migrateLegacyRegions {
    NSString *key = @"mod9MigratedLegacyRegions";
    if ([[NSUserDefaults standardUserDefaults] boolForKey:key]) {
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (CLRegion *legacy in self.manager.monitoredRegions) {
        if ([legacy isKindOfClass:[CLCircularRegion class]]) {
            CLCircularRegion *c = (CLCircularRegion *)legacy;
            if (!self.regions[c.identifier]) {
                OwnTracksLogDefault("[LocationManager] migrate %{public}@", c.identifier);
                [self startRegion:[OTRegion regionWithIdentifier:c.identifier
                                                          center:c.center
                                                          radius:c.radius]];
            }
        }
        [self.manager stopMonitoringForRegion:legacy];
    }
#pragma clang diagnostic pop
    [[NSUserDefaults standardUserDefaults] setBool:TRUE forKey:key];
}

- (void)setKnownState:(OTRegion *)region inside:(BOOL)inside {
    // mod18: 状態が変わったら、その場所の判定待ちの印を消す（どの経路でも）
    NSNumber *before = self.knownStates[region.identifier];
    if (!before || before.boolValue != inside) {
        [self clearStreaks:region.identifier];
    }
    self.knownStates[region.identifier] = @(inside);
    if (inside) {
        self.insideCircularRegions[region.identifier] = [NSNumber numberWithBool:TRUE];
    } else {
        [self.insideCircularRegions removeObjectForKey:region.identifier];
    }
    [self.delegate regionState:region inside:inside];
}

- (void)clearStreaks:(NSString *)identifier {
    [self.exitStreak removeObjectForKey:identifier];
    [self.exitFirst removeObjectForKey:identifier];
    [self.enterStreak removeObjectForKey:identifier];
    [self.enterFirst removeObjectForKey:identifier];
}

// 記録済みの最後の状態を読むだけ（出入りのイベントにはしない）
- (void)refreshRegionStates {
    if (!self.monitor) {
        return;
    }
    for (NSString *identifier in self.monitor.monitoredIdentifiers) {
        OTRegion *region = [self regionForIdentifier:identifier monitor:self.monitor];
        CLMonitoringEvent *last = [self.monitor monitoringRecordForIdentifier:identifier].lastEvent;
        if (region && last &&
            (last.state == CLMonitoringStateSatisfied || last.state == CLMonitoringStateUnsatisfied)) {
            [self setKnownState:region inside:(last.state == CLMonitoringStateSatisfied)];
        }
    }
}

- (void)monitor:(CLMonitor *)monitor event:(CLMonitoringEvent *)event {
    NSString *identifier = event.identifier;
    OwnTracksLogDefault("[LocationManager] monitor event %{public}@ state=%ld",
                        identifier, (long)event.state);
    if (event.authorizationDenied || event.authorizationDeniedGlobally ||
        event.authorizationRestricted || event.insufficientlyInUse ||
        event.serviceSessionRequired || event.conditionLimitExceeded ||
        event.conditionUnsupported || event.persistenceUnavailable || event.accuracyLimited) {
        OwnTracksLogError("[LocationManager] monitor problem %{public}@ denied=%d global=%d restricted=%d inUse=%d session=%d limit=%d unsupported=%d persist=%d accuracy=%d",
                          identifier, event.authorizationDenied, event.authorizationDeniedGlobally,
                          event.authorizationRestricted, event.insufficientlyInUse,
                          event.serviceSessionRequired, event.conditionLimitExceeded,
                          event.conditionUnsupported, event.persistenceUnavailable, event.accuracyLimited);
    }

    OTRegion *region = [self regionForIdentifier:identifier monitor:monitor];
    if (!region) {
        return;
    }

    if (event.state == CLMonitoringStateUnmonitored) {
        // 黙って監視が外れることがある（Customer.io SDKの知見）。置き直す
        OwnTracksLogError("[LocationManager] unmonitored %{public}@ -> re-add", identifier);
        [self startRegion:region];
        return;
    }
    if (event.state != CLMonitoringStateSatisfied && event.state != CLMonitoringStateUnsatisfied) {
        return;
    }
    BOOL inside = (event.state == CLMonitoringStateSatisfied);

    // 置いた直後の最初の判定は状態だけ（旧APIのdidDetermineStateと同じ扱い）
    if ([self.initialPending containsObject:identifier]) {
        [self.initialPending removeObject:identifier];
        [self setKnownState:region inside:inside];
        return;
    }

    // 変化が無ければイベントにしない。未知なら記録の前回の状態（処理中のイベントの1つ前）と比べる
    NSNumber *previous = self.knownStates[identifier];
    if (!previous) {
        CLMonitoringEvent *last = [monitor monitoringRecordForIdentifier:identifier].lastEvent;
        if (last && (last.state == CLMonitoringStateSatisfied || last.state == CLMonitoringStateUnsatisfied)) {
            previous = @(last.state == CLMonitoringStateSatisfied);
        }
    }
    if (previous && previous.boolValue == inside) {
        return;
    }

    if (inside) {
        if (![self removeHoldDown:region]) {
            OwnTracksLogDefault("[LocationManager] enter %{public}@", identifier);
            // mod18: 場所の円は、測った点で決まったときに状態を変える（flushRegionEvents）
            if (region.isFollow) {
                [self setKnownState:region inside:TRUE];
            }
            [self measureRegionEvent:region enter:YES];
        } else {
            self.knownStates[identifier] = @(TRUE);
        }
    } else {
        if ([identifier hasPrefix:@"-"]) {
            [self removeHoldDown:region];
            self.knownStates[identifier] = @(FALSE);
            [self.pendingRegionEvents addObject:[PendingRegionEvent holdDown:region for:3.0 to:self]];
        } else {
            OwnTracksLogDefault("[LocationManager] exit %{public}@", identifier);
            if (region.isFollow) {
                [self setKnownState:region inside:FALSE];
            }
            [self measureRegionEvent:region enter:NO];
        }
    }
}

// mod17: iOSの出入りの知らせ。追いかけの円はすぐ渡す。場所の円は、出ならmodeを先に変え、1点測る。
// mod18: 送るかは測った点で決める（flushRegionEvents）。知らせは測る合図
- (void)measureRegionEvent:(OTRegion *)region enter:(BOOL)enter {
    if (region.isFollow) {
        [self.delegate regionEvent:region enter:enter];
        return;
    }
    if (!enter) {
        [self.delegate regionMode:region enter:NO];
    }
    [self.measureEvents addObject:@[region, @(enter), [NSDate date]]];
    OwnTracksLogDefault("[LocationManager] measure %{public}@ %{public}@", enter ? @"enter" : @"exit", region.identifier);
    if (self.measureTask == UIBackgroundTaskInvalid) {
        __weak LocationManager *weakSelf = self;
        self.measureTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"measure" expirationHandler:^{
            OwnTracksLogDefault("[LocationManager] measure expired");
            [weakSelf flushRegionEvents:weakSelf.boostBest ? weakSelf.boostBest : weakSelf.manager.location];
        }];
    }
    [self.manager startUpdatingLocation];
    if (!self.boostStart) {
        [self startBoost];
    }
}

// mod18: 測った点（無ければ手元の最良の点）で判定する。知らせより後の精度20m以内の点が、入なら半径の中、
// 出なら半径の外のときだけ送り、そこで状態を変える。それ以外は送らず状態もそのまま（後の点で自分の判定に任せる）。
// 出で、精度の良い点が中だったら、先に変えたmodeをその場所の「入」のmodeへ戻す
- (void)flushRegionEvents:(CLLocation *)location {
    NSArray<NSArray *> *events = [self.measureEvents copy];
    [self.measureEvents removeAllObjects];
    CLLocation *at = location ? location : self.manager.location;
    for (NSArray *e in events) {
        OTRegion *region = e[0];
        BOOL enter = [e[1] boolValue];
        NSDate *notified = e[2];
        NSString *identifier = region.identifier;
        if (self.knownStates[identifier] && self.knownStates[identifier].boolValue == enter) {
            OwnTracksLogDefault("[LocationManager] measure skip %{public}@ (already)", identifier);
            continue;
        }
        BOOL fresh = at && [at.timestamp timeIntervalSinceDate:notified] >= 0;
        BOOL good = fresh && [self goodFix:at];
        CLLocationDistance d = -1;
        if (at) {
            CLLocation *center = [[CLLocation alloc] initWithLatitude:region.center.latitude
                                                            longitude:region.center.longitude];
            d = [at distanceFromLocation:center];
        }
        BOOL match = good && (enter ? d <= region.radius : d > region.radius);
        OwnTracksLogDefault("[LocationManager] measured %{public}@ %{public}@ acc=%.0f fresh=%d d=%.0f r=%.0f -> %{public}@",
                            enter ? @"enter" : @"exit", identifier, at ? at.horizontalAccuracy : -1.0,
                            fresh, d, region.radius, match ? @"send" : @"skip");
        if (!match) {
            if (!enter && good) {
                [self.delegate regionMode:region enter:YES];
            }
            continue;
        }
        [self setKnownState:region inside:enter];
        self.eventLocation = at;
        [self.delegate regionEvent:region enter:enter];
        self.eventLocation = nil;
    }
    if (self.monitoring != LocationMonitoringMove && !self.wakeChecking && !self.boostStart) {
        [self.manager stopUpdatingLocation];
    }
    if (self.measureTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.measureTask];
        self.measureTask = UIBackgroundTaskInvalid;
    }
}

- (void)startRegion:(OTRegion *)region {
    if (!region || region.radius <= 0) {
        return;
    }
    self.regions[region.identifier] = region;
    CLCircularGeographicCondition *condition =
    [[CLCircularGeographicCondition alloc] initWithCenter:region.center radius:region.radius];
    NSString *identifier = region.identifier;
    if (region.isFollow) {
        // 今いる場所に置くので中にいる前提。出たときだけイベントが来る
        [self.initialPending removeObject:identifier];
        self.knownStates[identifier] = @(TRUE);
        self.insideCircularRegions[identifier] = [NSNumber numberWithBool:TRUE];
        [self withMonitor:^(CLMonitor *monitor) {
            [monitor addConditionForMonitoring:condition
                                    identifier:identifier
                                  assumedState:CLMonitoringStateSatisfied];
        }];
    } else {
        [self.initialPending addObject:identifier];
        [self withMonitor:^(CLMonitor *monitor) {
            [monitor addConditionForMonitoring:condition identifier:identifier];
        }];
    }
}

- (void)stopRegion:(OTRegion *)region {
    if (region) {
        [self stopIdentifier:region.identifier];
    }
}

- (void)stopIdentifier:(NSString *)identifier {
    OTRegion *region = self.regions[identifier];
    if (region) {
        [self removeHoldDown:region];
    }
    [self.regions removeObjectForKey:identifier];
    [self clearStreaks:identifier];
    [self.knownStates removeObjectForKey:identifier];
    [self.initialPending removeObject:identifier];
    [self.insideCircularRegions removeObjectForKey:identifier];
    [self withMonitor:^(CLMonitor *monitor) {
        [monitor removeConditionFromMonitoringWithIdentifier:identifier];
    }];
}

- (void)resetRegions {
    for (NSString *identifier in [self.regions.allKeys copy]) {
        [self stopIdentifier:identifier];
    }
    [self withMonitor:^(CLMonitor *monitor) {
        for (NSString *identifier in [monitor.monitoredIdentifiers copy]) {
            [monitor removeConditionFromMonitoringWithIdentifier:identifier];
        }
    }];
}

- (BOOL)monitoredRegion:(NSString *)identifier {
    return (self.regions[identifier] != nil);
}

- (BOOL)insideCircularRegion {
    return (self.insideCircularRegions.count != 0);
}

- (BOOL)insideCircularRegion:(NSString *)identifier {
    NSNumber *number = (self.insideCircularRegions)[identifier];
    return (number ? number.boolValue : false);
}

- (CLLocation *)location {
    // mod12: 直前に判定へ使った点があれば、それを出入りの送信に付ける
    if (self.judgedLocation && -[self.judgedLocation.timestamp timeIntervalSinceNow] < 30.0) {
        _lastUsedLocation = self.judgedLocation;
        return self.judgedLocation;
    }
    if (self.manager.location) {
        _lastUsedLocation = self.manager.location;
    } else {
        OwnTracksLogDebug("[LocationManager] location == nil");
    }
    return self.lastUsedLocation;
}

- (void)setMinDist:(double)minDist {
    _minDist = minDist;
    self.monitoring = self.monitoring;
}

- (void)setMinTime:(double)minTime {
    _minTime = minTime;
    self.monitoring = self.monitoring;
}

- (void)setMonitoring:(LocationMonitoring)monitoring {
    OwnTracksLogDefault("[LocationManager] set monitoring=%ld", (long)monitoring);
    if (monitoring != LocationMonitoringMove &&
        monitoring != LocationMonitoringManual &&
        monitoring != LocationMonitoringQuiet &&
        monitoring != LocationMonitoringSignificant) {
        monitoring = LocationMonitoringQuiet;
        OwnTracksLogDefault("[LocationManager] monitoring set to %ld", (long)monitoring);
    }
    _monitoring = monitoring;
    // mod14: 起こされた確認の途中でmode 1以外になったら、確認を終える
    // （印が残ると、次の毎分の点が確認の結果として扱われ、送られなかった: 2026-11-07 16:37）
    if (self.wakeChecking && monitoring != LocationMonitoringSignificant) {
        OwnTracksLogDefault("[LocationManager] wake check cancel (mode %ld)", (long)monitoring);
        self.wakeChecking = FALSE;
        self.lastWakeCheckEnd = [NSDate date];
        if (self.wakeTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:self.wakeTask];
            self.wakeTask = UIBackgroundTaskInvalid;
        }
    }
    if (monitoring == LocationMonitoringMove) {
        [self.recentFixes removeAllObjects];
    }
    self.manager.pausesLocationUpdatesAutomatically = NO;
    self.manager.allowsBackgroundLocationUpdates = TRUE;
    
    switch (monitoring) {
        case LocationMonitoringMove:
            // 改造1・C: 普段は基地局程度の精度で動かし、GPSを使わない
            [self endBoost];
            self.manager.distanceFilter = LOW_DISTANCE_FILTER;
            self.manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
            [self.activityTimer invalidate];
            
            [self.manager startUpdatingLocation];
            [self.manager stopMonitoringSignificantLocationChanges];
            [self.manager stopMonitoringVisits];

            if (self.minTime > 0.0) {
                self.activityTimer = [NSTimer timerWithTimeInterval:self.minTime
                                                             target:self selector:@selector(activityTimer:)
                                                           userInfo:Nil
                                                            repeats:YES];
                [[NSRunLoop currentRunLoop] addTimer:self.activityTimer
                                             forMode:NSRunLoopCommonModes];
            }
            break;
            
        case LocationMonitoringSignificant:
            [self.activityTimer invalidate];
            [self endBoost];
            [self.manager stopUpdatingLocation];
            [self.manager startMonitoringSignificantLocationChanges];
            [self.manager startMonitoringVisits];
            break;
            
        case LocationMonitoringManual:
        case LocationMonitoringQuiet:
        default:
            [self.activityTimer invalidate];
            [self endBoost];
            [self.manager stopUpdatingLocation];
            [self.manager stopMonitoringSignificantLocationChanges];
            [self.manager stopMonitoringVisits];
            break;
    }
    NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:@"group.org.owntracks.Owntracks"];
    [shared setInteger:self.monitoring forKey:@"monitoring"];
}

- (void)setRanging:(BOOL)ranging {
    OwnTracksLogDefault("[LocationManager] set ranging=%d", ranging);
    _ranging = ranging; // 改造R6: ビーコンの測距は削除（値は保持するだけ）
    [self refreshRegionStates];
}

- (void)activityTimer:(NSTimer *)timer {
    OwnTracksLogDebug("[LocationManager] activityTimer fired after %f", self.minTime);
    // 前回の取得が止まったまま残っていたら片付ける（背景で止められたとき）
    if (self.boostStart && -[self.boostStart timeIntervalSinceNow] > BOOST_SECONDS * 3) {
        OwnTracksLogDefault("[LocationManager] boost stale, reset");
        [self endBoost];
        self.wakeChecking = FALSE;
    }
    if (self.boostStart) return;
    [self startBoost];
}

// 改造2: Bestへ上げ、精度BOOST_ACCURACY以内の点かBOOST_SECONDS経過で1点採用する
- (void)startBoost {
    self.boostStart = [NSDate date];
    self.boostBest = nil;
    self.manager.distanceFilter = kCLDistanceFilterNone;
    self.manager.desiredAccuracy = kCLLocationAccuracyBest;
    OwnTracksLogDefault("[LocationManager] boost start");
    self.boostTimer = [NSTimer timerWithTimeInterval:BOOST_SECONDS
                                              target:self selector:@selector(boostExpired:)
                                            userInfo:nil
                                             repeats:NO];
    [[NSRunLoop currentRunLoop] addTimer:self.boostTimer forMode:NSRunLoopCommonModes];
}

- (void)boostExpired:(NSTimer *)timer {
    CLLocation *location = self.boostBest ? self.boostBest : self.manager.location;
    OwnTracksLogDefault("[LocationManager] boost timeout acc=%.0f",
                        location ? location.horizontalAccuracy : -1.0);
    // mod13: 精度の悪い取得が2回続いたら、1回だけ取り直す
    if (![self goodFix:location]) {
        self.badFixStreak++;
        if (self.badFixStreak >= 2 && !self.boostRetried) {
            self.boostRetried = TRUE;
            OwnTracksLogDefault("[LocationManager] boost retry bad=%ld", (long)self.badFixStreak);
            [self startBoost];
            return;
        }
    }
    [self finishBoost:location];
}

- (void)finishBoost:(CLLocation *)location {
    if ([self goodFix:location]) {
        self.badFixStreak = 0;
    }
    self.boostRetried = FALSE;
    [self endBoost];
    if (self.measureEvents.count) {
        [self flushRegionEvents:location];
    }
    BOOL wake = self.wakeChecking;
    if (wake) {
        // mod17: 1点目が精度良く場所の円の外なら、続けてもう1点測る
        if (!self.wakeFirst && [self goodFix:location] && ![self placeAt:location]) {
            self.wakeFirst = location;
            OwnTracksLogDefault("[LocationManager] wake check first outside acc=%.0f", location.horizontalAccuracy);
            [self startBoost];
            return;
        }
        [self finishWakeCheck:location];
        return;
    }
    if (location) {
        self.lastUsedLocation = location;
        self.judgedLocation = location;
        [self checkOwnRegions:location];
        [self checkStationary:location];
        [self.delegate timerLocation:location];
    } else {
        OwnTracksLogError("[LocationManager] activityTimer found no location");
    }
}

- (BOOL)goodFix:(CLLocation *)location {
    return location && location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= BOOST_ACCURACY;
}

// 改造mod11: Moveの間は、精度の良い点が範囲の半径の外に出たら「出」、中に入ったら「入」とする（iOSを待たずにすぐ送られる）。
// 後から来るiOSの出入りは、状態が同じなのでイベントにならない
- (void)checkOwnRegions:(CLLocation *)location {
    if (self.monitoring != LocationMonitoringMove) {
        return;
    }
    [self judgeRegions:location src:@"move"];
}

// 場所の円（+・-で始まらない範囲）の出入りを、精度の良い点で判定する（mod12: mode 1で起こされたときも使う）
// mod13: 「出」は円の外の点が2点続いたら。訪問の通知で起こされたときは「出」を判定しない。判定は1行のログに出す
- (void)judgeRegions:(CLLocation *)location src:(NSString *)src {
    if (![self goodFix:location]) {
        OwnTracksLogDefault("[LocationManager] judge src=%{public}@ acc=%.0f -> skip (bad fix)",
                            src, location ? location.horizontalAccuracy : -1.0);
        return;
    }
    BOOL allowExit = ![src isEqualToString:@"visit"];
    NSString *near = @"-";
    CLLocationDistance nearD = -1, nearR = -1;
    NSString *result = @"none";
    LocationMonitoring start = self.monitoring;
    for (OTRegion *region in [self.regions.allValues copy]) {
        NSString *identifier = region.identifier;
        if ([identifier hasPrefix:@"+"] || [identifier hasPrefix:@"-"] || region.radius <= 0) {
            continue;
        }
        // 出入りでmodeが変わったら、それ以降は判定しない
        if (self.monitoring != start) {
            break;
        }
        CLLocation *center = [[CLLocation alloc] initWithLatitude:region.center.latitude
                                                        longitude:region.center.longitude];
        CLLocationDistance d = [location distanceFromLocation:center];
        BOOL inside = self.insideCircularRegions[identifier] != nil;
        if (nearD < 0 || d - region.radius < nearD - nearR) {
            near = identifier; nearD = d; nearR = region.radius;
        }
        if (inside && d > region.radius) {
            if (!allowExit) {
                result = [NSString stringWithFormat:@"exit skipped (visit) %@", identifier];
                continue;
            }
            NSInteger n = self.exitStreak[identifier].integerValue + 1;
            if (n < 2) {
                self.exitStreak[identifier] = @(n);
                self.exitFirst[identifier] = location;
                result = [NSString stringWithFormat:@"exit pending %@", identifier];
                continue;
            }
            [self.exitStreak removeObjectForKey:identifier];
            // mod13: 出の時刻・位置は、外に出た1点目にする
            self.eventLocation = self.exitFirst[identifier] ? self.exitFirst[identifier] : location;
            [self.exitFirst removeObjectForKey:identifier];
            OwnTracksLogDefault("[LocationManager] own exit %{public}@ d=%.0f r=%.0f",
                                identifier, d, region.radius);
            result = [NSString stringWithFormat:@"exit %@", identifier];
            [self setKnownState:region inside:FALSE];
            [self.delegate regionEvent:region enter:NO];
            self.eventLocation = nil;
        } else if (!inside && d <= region.radius) {
            // mod18: 「入」も中の点が2点続いたら。時刻・位置は中に入った1点目
            NSInteger n = self.enterStreak[identifier].integerValue + 1;
            if (n < 2) {
                self.enterStreak[identifier] = @(n);
                self.enterFirst[identifier] = location;
                result = [NSString stringWithFormat:@"enter pending %@", identifier];
                continue;
            }
            CLLocation *first = self.enterFirst[identifier];
            OwnTracksLogDefault("[LocationManager] own enter %{public}@ d=%.0f r=%.0f",
                                identifier, d, region.radius);
            result = [NSString stringWithFormat:@"enter %@", identifier];
            [self setKnownState:region inside:TRUE];
            self.eventLocation = first ? first : location;
            [self.delegate regionEvent:region enter:YES];
            self.eventLocation = nil;
        } else if (inside) {
            [self.exitStreak removeObjectForKey:identifier];
            [self.exitFirst removeObjectForKey:identifier];
        } else {
            [self.enterStreak removeObjectForKey:identifier];
            [self.enterFirst removeObjectForKey:identifier];
        }
    }
    OwnTracksLogDefault("[LocationManager] judge src=%{public}@ acc=%.0f mode=%ld->%ld near=%{public}@ d=%.0f r=%.0f -> %{public}@",
                        src, location.horizontalAccuracy, (long)start, (long)self.monitoring,
                        near, nearD, nearR, result);
    // 場所の円に入ってmode 1になったら、起こされるように追いかけの円をここに置く
    if (start != LocationMonitoringSignificant && self.monitoring == LocationMonitoringSignificant) {
        [self armFollowAt:location];
    }
}

// 入っている場所の円（+・-以外）。無ければnil
- (OTRegion *)insidePlace {
    for (NSString *identifier in self.insideCircularRegions.allKeys) {
        if ([identifier hasPrefix:@"+"] || [identifier hasPrefix:@"-"]) {
            continue;
        }
        OTRegion *region = self.regions[identifier];
        if (region) {
            return region;
        }
    }
    return nil;
}

// mod12: 直近5分の精度の良い点がSTATIONARY_MIN_POINTS点以上、すべて最新の点からSTATIONARY_SPREAD以内なら静止。
// 場所の円の中ならその場所の「入」のmode、外ならmode 1にして静止の円と追いかけの円を置く
- (void)checkStationary:(CLLocation *)location {
    if (self.monitoring != LocationMonitoringMove || ![self goodFix:location]) {
        return;
    }
    [self.recentFixes addObject:location];
    NSDate *now = location.timestamp;
    NSPredicate *recent = [NSPredicate predicateWithBlock:^BOOL(CLLocation *p, NSDictionary *b) {
        return [now timeIntervalSinceDate:p.timestamp] <= STATIONARY_SECONDS;
    }];
    [self.recentFixes filterUsingPredicate:recent];
    if (self.recentFixes.count < STATIONARY_MIN_POINTS) {
        return;
    }
    for (CLLocation *p in self.recentFixes) {
        if ([p distanceFromLocation:location] > STATIONARY_SPREAD) {
            return;
        }
    }
    // 中心は直近4分の点の平均（最初の点はまだ動いていたかもしれない）
    double lat = 0, lon = 0;
    int n = 0;
    for (CLLocation *p in self.recentFixes) {
        if ([now timeIntervalSinceDate:p.timestamp] <= STATIONARY_CENTER_SECONDS) {
            lat += p.coordinate.latitude;
            lon += p.coordinate.longitude;
            n++;
        }
    }
    CLLocation *center = [[CLLocation alloc] initWithLatitude:lat / n longitude:lon / n];

    LocationMonitoring newMonitoring = LocationMonitoringSignificant;
    OTRegion *place = [self insidePlace];
    if (place) {
        NSArray <NSString *> *components = [place.identifier componentsSeparatedByString:@"|"];
        if (components.count == 3) {
            newMonitoring = components[1].integerValue;
        }
    }
    OwnTracksLogDefault("[LocationManager] stationary n=%lu place=%{public}@ -> %ld",
                        (unsigned long)self.recentFixes.count, place ? place.identifier : @"-", (long)newMonitoring);
    [self.recentFixes removeAllObjects];
    self.monitoring = newMonitoring;
    if (newMonitoring == LocationMonitoringSignificant) {
        [self armFollowAt:place ? location : center];
    }
    NSManagedObjectContext *moc = CoreData.sharedInstance.mainMOC;
    [Settings setInt:(int)newMonitoring forKey:@"monitoring_preference" inMOC:moc];
    [CoreData.sharedInstance sync:moc];
}

// 追いかけの円（+で始まる範囲）を、この点を中心に最小の半径で置き直す
- (void)armFollowAt:(CLLocation *)location {
    for (OTRegion *region in [self.regions.allValues copy]) {
        if (region.isFollow) {
            OTRegion *r = [OTRegion regionWithIdentifier:region.identifier
                                                  center:location.coordinate
                                                  radius:FOLLOW_MIN_RADIUS];
            OwnTracksLogDefault("[LocationManager] follow armed %{public}@ r=%.0f", r.identifier, r.radius);
            [self startRegion:r];
        }
    }
}

// mod17: この点が入っている場所の円（+・-以外、知っている状態でなく距離で見る）。無ければnil
- (OTRegion *)placeAt:(CLLocation *)location {
    for (OTRegion *region in self.regions.allValues) {
        if ([region.identifier hasPrefix:@"+"] || [region.identifier hasPrefix:@"-"] || region.radius <= 0) {
            continue;
        }
        CLLocation *c = [[CLLocation alloc] initWithLatitude:region.center.latitude longitude:region.center.longitude];
        if ([location distanceFromLocation:c] <= region.radius) {
            return region;
        }
    }
    return nil;
}

// mod12: mode 1で起こされたら（追いかけの円の出・大きな移動・訪問）、すぐ精度の良い点を取って判定する
- (void)startWakeCheck:(NSString *)reason {
    if (self.monitoring != LocationMonitoringSignificant || self.wakeChecking) {
        return;
    }
    // mod13: 大きな移動の通知は、起こされた判定の直後（60秒以内）なら確かめ直さない（起動時の2回目を防ぐ）
    if ([reason isEqualToString:@"significant"] && self.lastWakeCheckEnd &&
        -[self.lastWakeCheckEnd timeIntervalSinceNow] < 60.0) {
        OwnTracksLogDefault("[LocationManager] wake check skip %{public}@ (recent)", reason);
        return;
    }
    if (self.boostStart) {
        [self endBoost];
    }
    OwnTracksLogDefault("[LocationManager] wake check start %{public}@", reason);
    self.wakeChecking = TRUE;
    self.wakeReason = reason;
    self.wakeFirst = nil;
    self.wakeTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"wakeCheck" expirationHandler:^{
        [[UIApplication sharedApplication] endBackgroundTask:self.wakeTask];
        self.wakeTask = UIBackgroundTaskInvalid;
    }];
    [self startBoost];
    [self.manager startUpdatingLocation];
}

- (void)finishWakeCheck:(CLLocation *)location {
    self.wakeChecking = FALSE;
    self.lastWakeCheckEnd = [NSDate date];
    NSString *reason = self.wakeReason;
    if (self.monitoring == LocationMonitoringSignificant) {
        [self.manager stopUpdatingLocation];
    }
    if (!location) {
        OwnTracksLogDefault("[LocationManager] wake check no location");
    } else {
        self.lastUsedLocation = location;
        self.judgedLocation = location;
        BOOL good = [self goodFix:location];
        [self judgeRegions:location src:reason ? reason : @"wake"];
        if (self.monitoring == LocationMonitoringSignificant) {
            OTRegion *place = [self insidePlace];
            // mod17: 1点目も場所の円の外だった（2点続けて外）ならMove。静止の円の距離は見ない
            BOOL twoOutside = self.wakeFirst != nil;
            // mod13: 場所の円の外の点が1点だけ（出の確定待ち）なら、Moveにして次の点で確かめる
            BOOL exitPending = self.exitStreak.count > 0;
            if (good && ((!place && twoOutside) || exitPending)) {
                OwnTracksLogDefault("[LocationManager] wake check %{public}@ acc=%.0f two=%d pending=%d -> move",
                                    reason, location.horizontalAccuracy, twoOutside, exitPending);
                // mode 1のうちに送る（すぐ送られる）。その後でMoveへ
                [self.delegate wakeLocation:location];
                self.monitoring = LocationMonitoringMove;
                NSManagedObjectContext *moc = CoreData.sharedInstance.mainMOC;
                [Settings setInt:(int)LocationMonitoringMove forKey:@"monitoring_preference" inMOC:moc];
                [CoreData.sharedInstance sync:moc];
            } else {
                OwnTracksLogDefault("[LocationManager] wake check acc=%.0f two=%d place=%{public}@ -> stay",
                                    location.horizontalAccuracy, twoOutside, place ? place.identifier : @"-");
                [self armFollowAt:location];
                if ([reason isEqualToString:@"follow"]) {
                    [self.delegate wakeLocation:location];
                }
            }
        } else {
            OwnTracksLogDefault("[LocationManager] wake check acc=%.0f -> %ld (region)",
                                location.horizontalAccuracy, (long)self.monitoring);
        }
    }
    if (self.wakeTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.wakeTask];
        self.wakeTask = UIBackgroundTaskInvalid;
    }
}

// 高精度の取得をやめて低い精度へ戻す（Move以外では精度は使わないので戻すだけ）
- (void)endBoost {
    [self.boostTimer invalidate];
    self.boostTimer = nil;
    self.boostStart = nil;
    self.boostBest = nil;
    self.manager.distanceFilter = LOW_DISTANCE_FILTER;
    self.manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
}

/*
 *
 * Delegate
 *
 */

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    OwnTracksLogDefault("[LocationManager] didChangeAuthorizationStatus to %d",
              manager.authorizationStatus);
    self.locationManagerAuthorizationStatus = manager.authorizationStatus;
    if (manager.authorizationStatus != kCLAuthorizationStatusAuthorizedAlways) {
        [self showError];
    }
}

- (void)showError {
    CLAuthorizationStatus status = self.manager.authorizationStatus;
    switch (status) {
        case kCLAuthorizationStatusAuthorizedAlways:
            break;
        case kCLAuthorizationStatusAuthorizedWhenInUse:
            [NavigationController alertWithTitle:@"LocationManager"
                                         message:
                 NSLocalizedString(@"App is not allowed to use location services in background",
                                   @"Location Manager error message")
            ];
            OwnTracksLogDefault("[LocationManager] %@", @"App is not allowed to use location services in background");
            break;
        case kCLAuthorizationStatusNotDetermined:
            [NavigationController alertWithTitle:@"LocationManager"
                                         message:
                 NSLocalizedString(@"App is not allowed to use location services yet",
                                   @"Location Manager error message")
            ];
            OwnTracksLogDefault("[LocationManager] %@", @"App is not allowed to use location services yet");
            break;
        case kCLAuthorizationStatusDenied:
            [NavigationController alertWithTitle:@"LocationManager"
                                         message:
                 NSLocalizedString(@"App is not allowed to use location services",
                                   @"Location Manager error message")
            ];
            OwnTracksLogDefault("[LocationManager] %@", @"App is not allowed to use location services");
            break;
        case kCLAuthorizationStatusRestricted:
            [NavigationController alertWithTitle:@"LocationManager"
                                         message:
                 NSLocalizedString(@"App use of location services is restricted",
                                   @"Location Manager error message")
            ];
            OwnTracksLogDefault("[LocationManager] %@", @"App use of location services is restricted");
            break;
        default:
            [NavigationController alertWithTitle:@"LocationManager"
                                         message:
                 NSLocalizedString(@"App use of location services is unclear",
                                   @"Location Manager error message")
            ];
            OwnTracksLogDefault("[LocationManager] %@", @"App use of location services is unclear");
            break;
    }
        
}

+ (NSString *)CLLocationText:(CLLocation *)location {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions |= NSISO8601DateFormatWithFractionalSeconds;

    return [NSString stringWithFormat:@"%g,%g(±%.0f,%.2f,%.2f)@%@",
            location.coordinate.longitude,
            location.coordinate.latitude,
            location.horizontalAccuracy,
            location.speed,
            location.course,
            [formatter stringFromDate:location.timestamp]];
}


- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray *)locations {
    OwnTracksLogDebug("[LocationManager] didUpdateLocations");
    
    int count = 0;
    for (CLLocation *location in locations) {
        count++;
        OwnTracksLogDefault("[LocationManager] Location#%d: %.0fs/%.0fs %.0fm/%.0fm %.0fs %@ %@ %@",
                  count,
                  self.lastUsedLocation ? [location.timestamp timeIntervalSinceDate:self.lastUsedLocation.timestamp] : 0,
                  self.minTime,
                  self.lastUsedLocation ? [location distanceFromLocation:self.lastUsedLocation] : 0,
                  self.minDist,
                  [location.timestamp timeIntervalSinceDate:self.lastLocationWithMovement.timestamp],
                  [LocationManager CLLocationText:location],
                  self.lastUsedLocation ? [LocationManager CLLocationText:self.lastUsedLocation] : @"nil",
                  [LocationManager CLLocationText:self.lastLocationWithMovement]
        );
        
        if (location.speed > ASSUME_NO_MOTION) {
            self.lastLocationWithMovement = location;
        }

        // 改造2: 高精度の取得中は、開始後の点のうち最も精度の良い点を覚え、基準に届いたら採用する
        if (self.boostStart && [location.timestamp timeIntervalSinceDate:self.boostStart] >= 0 &&
            location.horizontalAccuracy >= 0) {
            if (!self.boostBest || location.horizontalAccuracy < self.boostBest.horizontalAccuracy) {
                self.boostBest = location;
            }
            if (location.horizontalAccuracy <= BOOST_ACCURACY) {
                OwnTracksLogDefault("[LocationManager] boost hit acc=%.0f", location.horizontalAccuracy);
                [self finishBoost:location];
                continue;
            }
        }

        if (self.lastUsedLocation &&
            [location.timestamp timeIntervalSinceDate:self.lastUsedLocation.timestamp] <= 0) {
            continue;
        }
        
        // mod12: Moveの粗い点と、起こされた後の取得中の点は送らない（送るのは毎分の点と判定に使った点）
        if (self.monitoring == LocationMonitoringMove || self.wakeChecking) {
            continue;
        }

        // 改造mod10: 範囲の監視の準備前は送らない（inregionsが空の点でWorkerが外出と誤判定するため）
        if (!self.monitor) {
            OwnTracksLogDefault("[LocationManager] location held (monitor not ready)");
            continue;
        }

        self.lastUsedLocation = location;
        [self.delegate newLocation:location];

        // mod17: mode 1で大きな移動の通知が来たら、精度の良い点で確かめる（静止の円の距離は見ない）
        if (self.monitoring == LocationMonitoringSignificant) {
            [self startWakeCheck:@"significant"];
        }
    }
}

- (void)locationManager:(CLLocationManager *)manager
       didFailWithError:(NSError *)error {
    OwnTracksLogError("[LocationManager] didFailWithError %{public}@", error.localizedDescription);
}

/*
 *
 * Regions（改造mod9: イベントはCLMonitorから。ここは出るときの3秒の待ちだけ）
 *
 */
- (BOOL)removeHoldDown:(OTRegion *)region {
    OwnTracksLogDebug("[LocationManager] removeHoldDown %@ [%lu]",
                      region.identifier, (unsigned long)self.pendingRegionEvents.count);

    for (PendingRegionEvent *p in [self.pendingRegionEvents copy]) {
        if ([p.region.identifier isEqualToString:region.identifier]) {
            OwnTracksLogDebug("[LocationManager] holdDownInvalidated %{public}@", region.identifier);
            [p.holdDownTimer invalidate];
            p.region = nil;
            [self.pendingRegionEvents removeObject:p];
            return TRUE;
        }
    }
    return FALSE;
}

- (void)holdDownExpired:(NSTimer *)timer {
    OwnTracksLogDebug("[LocationManager] holdDownExpired %{public}@", timer.userInfo);
    if ([timer.userInfo isKindOfClass:[PendingRegionEvent class]]) {
        PendingRegionEvent *p = (PendingRegionEvent *)timer.userInfo;
        OTRegion *region = p.region;
        if (region) {
            OwnTracksLogDebug("[LocationManager] holdDownExpired %{public}@", region.identifier);
            [self removeHoldDown:region];
            [self setKnownState:region inside:FALSE];
            [self.delegate regionEvent:region enter:NO];
        }
    }
}

/*
 *
 * Deferred Updates
 *
 */
- (void)locationManager:(CLLocationManager *)manager didFinishDeferredUpdatesWithError:(NSError *)error {
    //
}

- (void)locationManagerDidPauseLocationUpdates:(CLLocationManager *)manager {
    //
}

- (void)locationManagerDidResumeLocationUpdates:(CLLocationManager *)manager {
    //
}

/*
 *
 * Heading
 *
 */
- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)newHeading {
    // we don't use heading
}

- (BOOL)locationManagerShouldDisplayHeadingCalibration:(CLLocationManager *)manager {
    // we don't use heading
    return false;
}

/*
 *
 * Visits
 *
 */
- (void)locationManager:(CLLocationManager *)manager didVisit:(CLVisit *)visit {
    OwnTracksLogDebug("[LocationManager] didVisit %g,%g ha=%g a=%@ d=%@",
                 visit.coordinate.latitude,
                 visit.coordinate.longitude,
                 visit.horizontalAccuracy,
                 visit.arrivalDate,
                 visit.departureDate);
    
    if (manager.location) {
        [self.delegate visitLocation:manager.location];
    }
    [self startWakeCheck:@"visit"];
}


- (void)startBackgroundTimer {
    OwnTracksLogDefault("[LocationManager] startBackgroundTimer");
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        if (!self.backgroundTimer || !self.backgroundTimer.isValid) {
            self.backgroundTimer = [NSTimer scheduledTimerWithTimeInterval:BACKGROUND_STOP_AFTER
                                                                    target:self
                                                                  selector:@selector(stopInBackground)
                                                                  userInfo:nil repeats:FALSE];
        }
    }
}

- (void)stopInBackground {
    OwnTracksLogDefault("[LocationManager] stopInBackground");
    self.backgroundTimer = nil;
    [self sleep];
}

@end

