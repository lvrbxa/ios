//
//  LocationManager.h
//  OwnTracks
//
//  Created by Christoph Krey on 21.10.14.
//  Copyright © 2014-2026  OwnTracks. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>

// 改造mod9: 範囲は自前の型で持つ（CLRegion系はiOS 27.3で非推奨。監視はCLMonitor）
@interface OTRegion : NSObject
@property (copy, nonatomic) NSString * _Nonnull identifier;
@property (nonatomic) CLLocationCoordinate2D center;
@property (nonatomic) CLLocationDistance radius;
@property (readonly, nonatomic) BOOL isFollow;
+ (OTRegion * _Nonnull)regionWithIdentifier:(NSString * _Nonnull)identifier
                                     center:(CLLocationCoordinate2D)center
                                     radius:(CLLocationDistance)radius;
@end

@protocol LocationManagerDelegate <NSObject>

- (void)newLocation:(CLLocation * _Nonnull)location;
- (void)timerLocation:(CLLocation * _Nonnull)location;
- (void)visitLocation:(CLLocation * _Nonnull)location;
- (void)wakeLocation:(CLLocation * _Nonnull)location;
- (void)regionEvent:(OTRegion * _Nonnull)region enter:(BOOL)enter;
- (void)regionState:(OTRegion * _Nonnull)region inside:(BOOL)inside;

@end

@interface LocationManager : NSObject <CLLocationManagerDelegate>

/**
 Enumeration of LocationMonitoring modes
 */
typedef NS_ENUM(NSInteger, LocationMonitoring) {
    LocationMonitoringQuiet = -1,
    LocationMonitoringManual,
    LocationMonitoringSignificant,
    LocationMonitoringMove
};


+ (LocationManager * _Nonnull) sharedInstance;
@property (weak, nonatomic) id<LocationManagerDelegate> delegate;
@property (nonatomic) LocationMonitoring monitoring;
@property (nonatomic) BOOL ranging;
@property (nonatomic) double minDist;
@property (nonatomic) double minTime;
@property (readonly, nonatomic) CLLocation * _Nonnull location;
@property (readonly, nonatomic) CLLocation * _Nonnull lastUsedLocation;
@property (readonly, nonatomic) CLLocation * _Nonnull lastLocationWithMovement;
// 改造mod9・案1: 改造Eで静止と判断してSignificantにした後、Moveになるまで真

@property (readonly, nonatomic) CLAuthorizationStatus locationManagerAuthorizationStatus;

@property (readonly, nonatomic) CMAuthorizationStatus altimeterAuthorizationStatus;
@property (readonly, nonatomic) BOOL altimeterIsRelativeAltitudeAvailable;
@property (readonly, nonatomic) CMAltitudeData * _Nullable altitudeData;

@property (readonly, nonatomic) CMAuthorizationStatus motionActivityManagerAuthorizationStatus;
@property (readonly, nonatomic) BOOL motionActivityManagerIsActivityAvailable;
@property (readonly, nonatomic) CMMotionActivity * _Nullable motionActivity;



- (void)start;
- (void)wakeup;
- (void)sleep;
- (void)stop;

- (void)startRegion:(OTRegion * _Nonnull)region NS_SWIFT_NAME(start(_:));
- (void)startWakeCheck:(NSString * _Nonnull)reason;
- (void)stopRegion:(OTRegion *_Nonnull)region NS_SWIFT_NAME(stop(_:));
- (void)resetRegions;
- (BOOL)monitoredRegion:(NSString *_Nonnull)identifier;

@property (NS_NONATOMIC_IOSONLY, readonly) BOOL insideCircularRegion;
- (BOOL)insideCircularRegion:(NSString * _Nonnull)identifier;
@property (readonly, strong, nonatomic) NSMutableDictionary * _Nonnull insideCircularRegions;
// mod13: 確定した「出」の、外に出た1点目（出入りの送信に使う）
@property (strong, nonatomic) CLLocation * _Nullable exitAtLocation;

@end

