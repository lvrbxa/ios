//
//  Waypoint+CoreDataClass.m
//  OwnTracks
//
//  Created by Christoph Krey on 30.05.18.
//  Copyright © 2018-2026 OwnTracks. All rights reserved.
//
//

#import "Waypoint+CoreDataClass.h"
#import "Friend+CoreDataClass.h"
#import <MapKit/MapKit.h>
#import <Contacts/Contacts.h>
#import "CoreData.h"
#import "LocationManager.h"

@implementation Waypoint

- (void)getReverseGeoCode {
    if (!self.placemark) {
        // 改造mod9: CLGeocoderはiOS 26で非推奨。MapKitの逆ジオコーディングを使う
        CLLocation *location = [[CLLocation alloc] initWithLatitude:(self.lat).doubleValue
                                                          longitude:(self.lon).doubleValue];
        MKReverseGeocodingRequest *request = [[MKReverseGeocodingRequest alloc] initWithLocation:location];
        [request getMapItemsWithCompletionHandler:
         ^(NSArray<MKMapItem *> *mapItems, NSError *error) {
             [self.managedObjectContext performBlock:^{
                 if (!self.isDeleted) {
                     NSString *full = mapItems.firstObject.address.fullAddress;
                     if (full.length > 0) {
                         self.placemark = full;
                     } else {
                         self.placemark = [NSString stringWithFormat:@"%@\n%@ %ld\n%@",
                                           NSLocalizedString(@"Address resolver failed", @"reverseGeocodeLocation error"),
                                           error.domain,
                                           (long)error.code,
                                           NSLocalizedString(@"due to rate limit or off-line", @"reverseGeocodeLocation text")
                                           ];
                     }
                     self.belongsTo.topic = self.belongsTo.topic;
                     [CoreData.sharedInstance sync:self.managedObjectContext];
                 }
             }];
         }];
    }
}

- (CLLocationDistance)getDistanceFrom:(CLLocation *)fromLocation {
    CLLocation *location = [[CLLocation alloc] initWithLatitude:(self.lat).doubleValue
                                                      longitude:(self.lon).doubleValue];
    return [location distanceFromLocation:fromLocation];
}

- (CLLocation *)location {
    
    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake((self.lat).doubleValue,
                                                                             (self.lon).doubleValue)
                                         altitude:(self.alt).doubleValue
                               horizontalAccuracy:(self.acc).doubleValue
                                 verticalAccuracy:(self.vac).doubleValue
                                           course:(self.cog).doubleValue
                                   courseAccuracy:0
                                            speed:(self.vel).doubleValue
                                    speedAccuracy:0
                                        timestamp:self.tst];
}

- (NSDate *)effectiveTimestamp {
    if (self.createdAt != nil &&
        self.createdAt.timeIntervalSince1970 > self.tst.timeIntervalSince1970) {
        return self.createdAt;
    }
    return self.tst;
}

- (NSString *)triggerText {
    if (self.trigger) {
        return self.trigger;
    } else {
        return @"-";
    }
}

- (NSString *)monitoringText {
    if (self.m) {
        switch (self.m.integerValue) {
            case LocationMonitoringMove:
                return NSLocalizedString(@"Move", @"Move");
            case LocationMonitoringSignificant:
                return NSLocalizedString(@"Significant", @"Significant");
            case LocationMonitoringManual:
                return NSLocalizedString(@"Manual", @"Manual");
            case LocationMonitoringQuiet:
                return NSLocalizedString(@"Quiet", @"Quiet");
            default:
                return self.m.stringValue;
        }
    } else {
        return @"-";
    }
}

- (NSString *)connectionText{
    if (self.conn && self.conn.length > 0) {
        return self.conn;
    } else {
        return @"-";
    }
}

- (NSString *)batteryStatusText {
    if (self.bs) {
        switch (self.bs.integerValue) {
            case 3:
                return NSLocalizedString(@"full", @"Battery status full");
            case 2:
                return NSLocalizedString(@"charging", @"Battery status charging");

            case 1:
                return NSLocalizedString(@"unplugged", @"Battery status unplugged");

            case 0:
            default:
                return NSLocalizedString(@"unknown", @"Battery status unknown");
        }
    } else {
        return @"-";
    }
}

- (NSString *)batteryLevelText {
    if (self.batt && self.batt.doubleValue >= 0.0) {
        NSString *text = [NSString stringWithFormat:@"%0.f%%",
                          (self.batt).doubleValue * 100.0
                          ];
        return text;
    } else {
        return @"-";
    }
}

- (NSString *)defaultPlacemark {
    return [NSString stringWithFormat:@"%@\n%@",
            NSLocalizedString(@"Address resolver disabled", @"Address resolver disabled"),
            [NSString stringWithFormat:@"%g,%g",
             (self.lat).doubleValue,
             (self.lon).doubleValue]
    ];
}

#pragma MKAnnotation

- (void)setCoordinate:(CLLocationCoordinate2D)newCoordinate {
    //
}

- (CLLocationCoordinate2D)coordinate {
    return CLLocationCoordinate2DMake((self.lat).doubleValue, (self.lon).doubleValue);
}

- (NSString *)title {
    return self.poi ? self.poi : self.placemark ? self.placemark : [NSString stringWithFormat:@"%g,%g",
                                                                    (self.lat).doubleValue,
                                                                    (self.lon).doubleValue];
}

- (NSString *)subtitle {
    return self.poi ? self.placemark : nil;
}

@end
