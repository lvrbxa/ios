//
//  RegionTVC.swift
//  OwnTracks
//
//  Created by Christoph Krey on 26.02.26.
//  Copyright © 2026 OwnTracks. All rights reserved.
//

import Foundation
import UIKit

@objc(RegionTVC)
class RegionTVC: UITableViewController, UITextFieldDelegate {
    @objc public var region: Region?;
    @objc public var editAllowed: NSNumber?;
    
    @IBOutlet weak var UIname: UITextField!
    @IBOutlet weak var UIuuid: UITextField!
    @IBOutlet weak var UImajor: UITextField!
    @IBOutlet weak var UIminor: UITextField!
    @IBOutlet weak var UIlatitude: UITextField!
    @IBOutlet weak var UIlongitude: UITextField!
    @IBOutlet weak var UIradius: UITextField!
    
    var needsUpdate: Bool = false;
    var oldRegion: OTRegion?;
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated);
        
        UIname.delegate = self;
        UIuuid.delegate = self;
        UImajor.delegate = self;
        UIminor.delegate = self;
        UIlatitude.delegate = self;
        UIlongitude.delegate = self;
        UIradius.delegate = self;
        
        title = region?.name;
        setup();
        oldRegion = region?.otRegion;
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        if needsUpdate {
            if region != nil {
                region!.name = UIname.text;
                region!.lat = NSNumber(value: (UIlatitude!.text! as NSString).doubleValue);
                region!.lon = NSNumber(value: (UIlongitude!.text! as NSString).doubleValue);
                region!.radius = NSNumber(value: (UIradius!.text! as NSString).doubleValue);
                region!.uuid = UIuuid.text;
                region!.major = NSNumber(value: (UImajor!.text! as NSString).intValue);
                region!.minor = NSNumber(value: (UIminor!.text! as NSString).intValue);
                
                let ad = UIApplication.shared.delegate as! OwnTracksAppDelegate;
                let lm = LocationManager.sharedInstance();
                ad.send(region!);
                if oldRegion != nil {
                    lm.stop(oldRegion!);
                }
                if region!.otRegion != nil {
                    lm.start(region!.otRegion!);
                }
                CoreData.sharedInstance().sync(region!.managedObjectContext!);
            }
        }
        super.viewWillDisappear(animated);
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder();
        return true;
    }
    
    private func setup() {
        if region != nil && editAllowed != nil {
            UIname.text = region!.name;
            UIname.isEnabled = editAllowed!.boolValue;
            
            UIlatitude.text = "\(NSString(format: "%.6f", region!.lat?.doubleValue ?? 0.0))";
            UIlatitude.isEnabled = editAllowed!.boolValue;
            
            UIlongitude.text = "\(NSString(format: "%.6f", region!.lon?.doubleValue ?? 0.0))";
            UIlongitude.isEnabled = editAllowed!.boolValue;
            
            UIradius.text = "\(NSString(format: "%.0f", region!.radius?.doubleValue ?? 0.0))";
            UIradius.isEnabled = editAllowed!.boolValue;
            
            UIuuid.text = region!.uuid;
            UIuuid.isEnabled = editAllowed!.boolValue;
            
            UImajor.text = "\(NSString(format: "%u", region!.major?.uintValue ?? 0))";
            UImajor.isEnabled = editAllowed!.boolValue;
            
            UIminor.text = "\(NSString(format: "%u", region!.minor?.uintValue ?? 0))";
            UIminor.isEnabled = editAllowed!.boolValue;
        }
    }
    
    @IBAction func tidchanged(_ sender: UITextField) {
        needsUpdate = true;
    }
    
    @IBAction func namechanged(_ sender: UITextField) {
        needsUpdate = true;
    }
    
    @IBAction func latitudechanged(_ sender: UITextField) {
        needsUpdate = true;
    }
    
    @IBAction func longitudechanged(_ sender: UITextField) {
        needsUpdate = true;
    }
    
    @IBAction func radiuschanged(_ sender: UITextField) {
        needsUpdate = true;
    }
    
    @IBAction func uuidchanged(_ sender: UITextField) {
        needsUpdate = true;
    }
    
    @IBAction func majorchanged(_ sender: UITextField) {
        needsUpdate = true;
    }
    
    @IBAction func minorchanged(_ sender: UITextField) {
        needsUpdate = true;
    }
    
    @IBAction func navigatePressed(_ sender: UIButton) {
        if region != nil {
            let coord = CLLocationCoordinate2DMake(region!.lat?.doubleValue ?? 0.0, region!.lon?.doubleValue ?? 0.0);
            let destination = MKMapItem(location: CLLocation(latitude: coord.latitude, longitude: coord.longitude), address: nil);
            destination.name = region!.name;
            MKMapItem.openMaps(with: [destination], launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]);
        }
    }

}

