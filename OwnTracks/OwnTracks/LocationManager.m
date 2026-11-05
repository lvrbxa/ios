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
// 改造E: モーションセンサーで静止が始まった時刻
@property (strong, nonatomic) NSDate *stationarySince;
@property (strong, nonatomic) NSMutableSet *pendingRegionEvents;
// 改造mod9: CLMonitor（起動のたびに同じ名前で作る。準備ができるまでの操作は積んでおく）
@property (strong, nonatomic) CLMonitor *monitor;
@property (strong, nonatomic) NSMutableArray *pendingMonitorOps;
@property (strong, nonatomic) NSMutableDictionary<NSString *, OTRegion *> *regions;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSNumber *> *knownStates;
@property (strong, nonatomic) NSMutableSet<NSString *> *initialPending;
@property (strong, nonatomic) CLLocation *lastBoostLocation;
@property (nonatomic) BOOL stationaryArmed;
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
#define STATIONARY_SECONDS 300.0 // 改造E: この秒数静止したらSignificantへ
#define STATIONARY_RADIUS 100.0 // 改造mod9・案1: 静止したときに置く+followの半径
#define STATIONARY_MAX_ACC 100.0 // 改造mod9・案1: 静止の範囲の中心に使える点の精度の上限
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
            // 改造E: 静止の始まりを覚え、動いたら消す
            if (activity.stationary && activity.confidence != CMMotionActivityConfidenceLow) {
                if (!self.stationarySince) self.stationarySince = activity.startDate;
            } else if (!activity.stationary) {
                self.stationarySince = nil;
            }
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
    self.knownStates[region.identifier] = @(inside);
    if (inside) {
        self.insideCircularRegions[region.identifier] = [NSNumber numberWithBool:TRUE];
    } else {
        [self.insideCircularRegions removeObjectForKey:region.identifier];
    }
    [self.delegate regionState:region inside:inside];
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
            [self setKnownState:region inside:TRUE];
            [self.delegate regionEvent:region enter:YES];
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
            [self setKnownState:region inside:FALSE];
            [self.delegate regionEvent:region enter:NO];
        }
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

// 改造mod9・案1: 静止した点（精度の良いboostの点）を中心に+followを小さく置き直す
- (void)armStationaryFollow {
    CLLocation *center = self.lastBoostLocation;
    if (!center || center.horizontalAccuracy < 0 || center.horizontalAccuracy > STATIONARY_MAX_ACC) {
        OwnTracksLogDefault("[LocationManager] stationary follow skipped (no precise point)");
        return;
    }
    for (OTRegion *region in [self.regions.allValues copy]) {
        if (region.isFollow) {
            OTRegion *r = [OTRegion regionWithIdentifier:region.identifier
                                                  center:center.coordinate
                                                  radius:MAX(STATIONARY_RADIUS, center.horizontalAccuracy)];
            OwnTracksLogDefault("[LocationManager] stationary follow %{public}@ r=%.0f",
                                r.identifier, r.radius);
            [self startRegion:r];
        }
    }
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
    self.stationaryArmed = FALSE; // 改造mod9・案1: 改造Eだけが切替の直後に真にする
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
    // 改造E: Moveで静止がSTATIONARY_SECONDS続いたらSignificantへ（再開は+followの出→Workerの返事）
    if (self.monitoring == LocationMonitoringMove && self.stationarySince &&
        -[self.stationarySince timeIntervalSinceNow] >= STATIONARY_SECONDS) {
        OwnTracksLogDefault("[LocationManager] stationary %.0fs -> significant",
                            -[self.stationarySince timeIntervalSinceNow]);
        self.stationarySince = nil;
        [self armStationaryFollow];
        self.monitoring = LocationMonitoringSignificant;
        self.stationaryArmed = TRUE;
        NSManagedObjectContext *moc = CoreData.sharedInstance.mainMOC;
        [Settings setInt:(int)LocationMonitoringSignificant forKey:@"monitoring_preference" inMOC:moc];
        [CoreData.sharedInstance sync:moc];
        return;
    }
    // 改造2: Bestへ上げ、精度BOOST_ACCURACY以内の点かBOOST_SECONDS経過で1点採用する
    if (self.boostStart) return;
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
    [self finishBoost:location];
}

- (void)finishBoost:(CLLocation *)location {
    [self endBoost];
    if (location) {
        if (location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= STATIONARY_MAX_ACC) {
            self.lastBoostLocation = location;
        }
        self.lastUsedLocation = location;
        [self.delegate timerLocation:location];
    } else {
        OwnTracksLogError("[LocationManager] activityTimer found no location");
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
        
        if (self.monitoring == LocationMonitoringMove &&
            self.lastUsedLocation &&
            [location distanceFromLocation:self.lastUsedLocation] < self.minDist) {
            continue;
        }

        self.lastUsedLocation = location;
        [self.delegate newLocation:location];
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

