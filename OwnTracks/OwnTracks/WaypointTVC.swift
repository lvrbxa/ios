//
//  WaypointTVC.swift
//  OwnTracks
//
//  Created by Christoph Krey on 17.03.26.
//  Copyright © 2026 OwnTracks. All rights reserved.
//

import Foundation
import UIKit
import Contacts

@objc(WaypointTVC)
class WaypointTVC: UITableViewController {
    @objc public var waypoint: Waypoint? = nil;
    
    @IBOutlet weak var UIcoordinate: UITextField!
    @IBOutlet weak var UIdistance: UITextField!
    @IBOutlet weak var UItrigger: UITextField!
    @IBOutlet weak var UImonitoring: UITextField!
    @IBOutlet weak var UIconnection: UITextField!
    @IBOutlet weak var UIregions: UITextField!
    @IBOutlet weak var UIplace: UILabel!
    @IBOutlet weak var UItimestamp: UITextField!
    @IBOutlet weak var UItopic: UITextField!
    @IBOutlet weak var UIinfo: UITextField!
    @IBOutlet weak var UIcreatedAt: UITextField!
    @IBOutlet weak var UIbatterylevel: UITextField!
    @IBOutlet weak var UIbatterystatus: UITextField!
    @IBOutlet weak var bookmarkButton: UIBarButtonItem!
    @IBOutlet weak var UIpoi: UITextField!
    @IBOutlet weak var UItag: UITextField!
    @IBOutlet weak var UIphoto: UIImageView!
    @IBOutlet weak var UIimageName: UITextField!
    @IBOutlet weak var UIpressure: UITextField!
    @IBOutlet weak var UImotionActivities: UITextField!

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated);
        
        let locked = Settings.theLocked(inMOC: CoreData.sharedInstance().mainMOC);
        let status = CNContactStore.authorizationStatus(for: .contacts);
        if locked || status != .authorized {
            navigationItem.rightBarButtonItem = nil;
        }
        
        tableView.estimatedRowHeight = 150;
        tableView.rowHeight = UITableView.automaticDimension;
        
        if waypoint != nil && waypoint!.managedObjectContext != nil && waypoint!.belongsTo != nil {
            
            title = waypoint!.belongsTo!.nameOrTopic;
            
            if UserDefaults.standard.integer(forKey: "noRevgeo") > 0 {
                waypoint!.getReverseGeoCode();
            } else {
                waypoint!.placemark = waypoint!.defaultPlacemark;
                waypoint!.belongsTo!.topic = waypoint!.belongsTo!.topic;
                CoreData.sharedInstance().sync(waypoint!.managedObjectContext!);
            }
        }
        setup();
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated);
        if waypoint != nil {
            waypoint?.removeObserver(self, forKeyPath: "placemark");
        }
    }
    
    private func setup() {
        if waypoint != nil {
            UIcoordinate.text = OwnTracksFormatter.coordinate(from: waypoint!.location);
            let distance = waypoint!.getDistanceFrom(LocationManager.sharedInstance().location);
            UIdistance.text = OwnTracksFormatter.distance(from: distance);
            
            UItrigger.text = waypoint!.triggerText;
            UImonitoring.text = waypoint!.monitoringText;
            UIconnection.text = waypoint!.connectionText;
            
            UIregions.text = "-";
            if waypoint!.inRegions != nil {
                do {
                    let inRegions = try JSONSerialization.jsonObject(with: waypoint!.inRegions!, options: []);
                    for inRegion in inRegions as! [String] {
                        if UIregions.text == "-" {
                            UIregions.text = inRegion;
                        } else {
                            UIregions.text = "\(UIregions.text!), \(inRegion)";
                        }
                    }
                } catch {
                }
            }
            
            UImotionActivities.text = "-";
            if waypoint!.motionActivities != nil {
                do {
                    let motionActivities = try JSONSerialization.jsonObject(with: waypoint!.motionActivities!, options: []);
                    for motionActivity in motionActivities as! [String] {
                        if UImotionActivities.text == "-" {
                            UImotionActivities.text = motionActivity;
                        } else {
                            UImotionActivities.text = "\(UImotionActivities.text!), \(motionActivity)";
                        }
                    }
                } catch {
                }
            }
             
            if waypoint!.pressure != nil {
                UIpressure.text = OwnTracksFormatter.pressure(from: waypoint!.pressure!.doubleValue);
            } else {
                UIpressure.text = NSLocalizedString("No pressure available",
                                                    comment: "No pressure available");
            }
            
            UItimestamp.text = OwnTracksFormatter.timestamp(from: waypoint!.tst);
            UIcreatedAt.text = OwnTracksFormatter.timestamp(from: waypoint!.createdAt); 
            let location = waypoint!.location;
            UIinfo.text =
                OwnTracksFormatter.altitude(from: location) + " " +
                OwnTracksFormatter.speed(from: location) + " " +
                OwnTracksFormatter.cog(from: location);
            UIbatterystatus.text = waypoint!.batteryStatusText;
            UIbatterylevel.text = waypoint!.batteryLevelText;
            UItopic.text = waypoint!.belongsTo?.topic;
            UIpoi.text = waypoint!.poi;
            UItag.text = waypoint!.tag;
            UIphoto.image = UIImage(data: waypoint!.image ?? Data());
            UIimageName.text = waypoint!.imageName;
            
            waypoint!.addObserver(self, forKeyPath: "placemark", options: [.new], context: nil);
            UIplace.text = waypoint?.placemark;
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        UIplace.text = waypoint?.placemark;
    }
    
    @IBAction func navigatePressed(_ sender: UIButton) {
        if waypoint != nil && waypoint!.lat != nil && waypoint!.lon != nil {
            let coord = CLLocationCoordinate2D(latitude: waypoint!.lat!.doubleValue, longitude: waypoint!.lon!.doubleValue);
            let destination = MKMapItem(location: CLLocation(latitude: coord.latitude, longitude: coord.longitude), address: nil);
            destination.name = waypoint!.belongsTo?.nameOrTopic;
            MKMapItem.openMaps(with: [destination],
                               launchOptions: [MKLaunchOptionsDirectionsModeKey:MKLaunchOptionsDirectionsModeDriving]);
        }
    }
    
    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if waypoint != nil {
            let tableViewCell = tableView.cellForRow(at: indexPath);
            if tableViewCell?.tag == 81 {
                let coordinate = waypoint!.coordinate;
                UIPasteboard.general.string = ("\(coordinate.latitude),\(coordinate.longitude)");
                NavigationController.alert(title: NSLocalizedString("Clipboard",
                                                                    comment: "Clipboard"),
                                           message: NSLocalizedString("Location copied to clipboard",
                                                                      comment:"Location copied to clipboard"),
                                           dismissAfter: 1.0);
            } else if tableViewCell?.tag == 82 {
                UIPasteboard.general.string = waypoint!.belongsTo?.topic;
                NavigationController.alert(title: NSLocalizedString("Clipboard",
                                                                    comment: "Clipboard"),
                                           message: NSLocalizedString("Topic copied to clipboard",
                                                                      comment:"Topic copied to clipboard"),
                                           dismissAfter: 1.0);
            }
        }
        return nil;
    }
}
