//
//  ViewController.swift
//  OwnTracks
//
//  Created by Christoph Krey on 19.03.26.
//  Copyright © 2026 OwnTracks. All rights reserved.
//

import Foundation
import UIKit
import MapKit
import WebKit
import AppIntents

// 改造R4: Basic認証はOwnTracksの設定のユーザー名・パスワードで答える
extension ViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let moc = CoreData.sharedInstance().mainMOC;
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
           challenge.previousFailureCount == 0,
           let u = Settings.string(forKey: "user_preference", inMOC: moc) as String?,
           let p = Settings.string(forKey: "pass_preference", inMOC: moc) as String? {
            completionHandler(.useCredential, URLCredential(user: u, password: p, persistence: .forSession));
        } else {
            completionHandler(.performDefaultHandling, nil);
        }
    }
}

// 改造①: ショートカットのWi-Fi切断から呼ぶ。画面を開かず、今の時刻で1点すぐ送ってからMoveにする
struct LeaveHomeIntent: AppIntent {
    static var title: LocalizedStringResource = "Leave Home";
    static var openAppWhenRun: Bool = false;

    @MainActor
    func perform() async throws -> some IntentResult {
        let lm = LocationManager.sharedInstance();
        let last = lm.location;
        if CLLocationCoordinate2DIsValid(last.coordinate),
           let app = UIApplication.shared.delegate as? OwnTracksAppDelegate {
            // 最後の点の位置に、今の時刻を付けて送る（Move以外ではまとめずにすぐ送られる）
            let now = CLLocation(coordinate: last.coordinate, altitude: last.altitude,
                                 horizontalAccuracy: last.horizontalAccuracy,
                                 verticalAccuracy: last.verticalAccuracy, timestamp: Date());
            _ = app.sendNow(now, withPOI: nil, withImage: nil, withImageName: nil);
        }
        if lm.monitoring != .move {
            lm.monitoring = .move;
            UserDefaults.standard.set(false, forKey: "downgraded");
            UserDefaults.standard.set(false, forKey: "adapted");
            Settings.setInt(Int32(LocationMonitoring.move.rawValue),
                            forKey: "monitoring_preference",
                            inMOC: CoreData.sharedInstance().mainMOC);
            CoreData.sharedInstance().sync(CoreData.sharedInstance().mainMOC);
        }
        // 送信が終わるまで少し待つ
        try? await Task.sleep(nanoseconds: 8_000_000_000);
        return .result();
    }
}

class ViewController: UIViewController, MKMapViewDelegate, NSFetchedResultsControllerDelegate {
    @IBOutlet weak var mapView: MKMapView!;
    @IBOutlet weak var actionButton: UIBarButtonItem!;
    @IBOutlet weak var privacyButton: UIBarButtonItem!;
    @IBOutlet weak var askForMapButton: UIBarButtonItem!;
    @IBOutlet weak var accuracyButton: UIBarButtonItem!;
        
    var trackingButton: MKUserTrackingButton? = nil;
    var modes: UISegmentedControl? = nil;
    var mapMode: UISegmentedControl? = nil;
    var scaleView: MKScaleView? = nil;
    
    var osmRenderer: MKTileOverlayRenderer? = nil;
    var osmCopyright: UITextField? = nil;
    var osmOverlay: MKTileOverlay? = nil;
    
    var suspendAutomaticTrackingOfChangesInManagedObjectContext: Bool = false;
    var warningShown: Bool = false;
    var initialCenter: Bool = false;
    
    var frcFriends: NSFetchedResultsController<Friend>? = nil;
    var frcRegions: NSFetchedResultsController<Region>? = nil;
    var frcWaypoints: NSFetchedResultsController<Waypoint>? = nil;
    
    override func viewDidLoad() {
        super.viewDidLoad();
        mapView.delegate = self;
        mapView.mapType = .standard;
        mapView.showsScale = false;
                
        setupModes();
        setupMapMode();
        setupScaleView();
        
        LocationManager.sharedInstance().addObserver(self,
                                                     forKeyPath: "monitoring",
                                                     options: [.new],
                                                     context: nil);
        mapView.addObserver(self,
                            forKeyPath: "userLocation",
                            options: [.initial, .new],
                            context: nil);
        mapView.addObserver(self,
                            forKeyPath: "userLocation.location",
                            options: [.initial, .new],
                            context: nil);
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name("reload"),
                                               object: nil,
                                               queue: OperationQueue.main) { notification in
            if Thread.isMainThread {
                self.reloaded();
            } else {
                DispatchQueue.main.async {
                    self.reloaded();
                }
            }
        }
        noMap();
        reloaded();
        showWebMap();
    }

    // 改造R4: Appleの地図は隠し、Workerの/map?src=xをアプリの中で表示する
    var webMap: WKWebView?;

    func showWebMap() {
        mapView.isHidden = true;
        let web = WKWebView(frame: .zero);
        web.navigationDelegate = self;
        web.translatesAutoresizingMaskIntoConstraints = false;
        view.addSubview(web);
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // モード切替（modes）を隠さないよう、その下から表示する
            modes != nil ? web.topAnchor.constraint(equalTo: modes!.bottomAnchor, constant: 6)
                         : web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ]);
        webMap = web;
        reloadWebMap();
    }

    // 送信先URL（…/pubx）の同じホストの/map?src=xを開く
    func reloadWebMap() {
        let moc = CoreData.sharedInstance().mainMOC;
        guard let s = Settings.string(forKey: "url_preference", inMOC: moc) as String?,
              var c = URLComponents(string: s) else { return; }
        c.path = "/map";
        c.query = "src=x";
        if let url = c.url { webMap?.load(URLRequest(url: url)); }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated);
        if webMap?.url != nil { webMap?.reload(); }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated);
        mapModeChanged(mapMode!);
        
        if !warningShown && Setting.existsSetting(withKey: "mode", inMOC: CoreData.sharedInstance().mainMOC) == nil {
            warningShown = true;
            NavigationController.alert(title: NSLocalizedString("Setup",
                                                                comment: "Header of an alert message regarding missing setup"),
                                       message: NSLocalizedString("You need to setup your own OwnTracks server and edit your configuration for full privacy protection. Detailed info on https://owntracks.org/booklet",
                                                                  comment: "Text explaining the Setup"));
        }
        
        if noMap() == 0 {
            askForMap(askForMapButton);
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "monitoring" {
            updateMoveButton();
        }
        if keyPath == "userLocation" || keyPath == "userLocation.location" {
            updateAccuracyButton();
        }
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "showWaypointFromMap" {
            if segue.destination is WaypointTVC {
                let waypointTVC = segue.destination as! WaypointTVC;
                if sender is MKAnnotationView {
                    let view = sender as! MKAnnotationView;
                    if view.annotation is Friend {
                        let friend = view.annotation as! Friend;
                        let waypoint = friend.newestWaypoint;
                        if waypoint != nil {
                            waypointTVC.waypoint = waypoint;
                        }
                    } else if view.annotation is Waypoint {
                        let waypoint = view.annotation as! Waypoint;
                        waypointTVC.waypoint = waypoint;
                    }
                }
            }
        } else if segue.identifier == "showRegionFromMap" {
            if segue.destination is RegionTVC {
                let regionTVC = segue.destination as! RegionTVC;
                let view = sender as! MKAnnotationView;
                let region = view.annotation as! Region;
                regionTVC.region = region;
                regionTVC.editAllowed = false;
            }
        }
    }
    
    func setupModes() {
        modes = UISegmentedControl(items: [NSLocalizedString("Quiet", comment: "Quiet"),
                                           NSLocalizedString("Manual", comment: "Manual"),
                                           NSLocalizedString("Significant", comment: "Significant"),
                                           NSLocalizedString("Move", comment: "Move")
                                          ]);
        modes!.apportionsSegmentWidthsByContent = true;
        modes!.translatesAutoresizingMaskIntoConstraints = false;
        modes!.backgroundColor = UIColor(named: "modesColor");
        modes!.addTarget(self, action: #selector(modesChanged(_:)), for: .valueChanged);
        view.addSubview(modes!);
        let topModes = NSLayoutConstraint(item: modes!,
                                          attribute: .top,
                                          relatedBy: .equal,
                                          toItem: mapView,
                                          attribute: .top,
                                          multiplier: 1,
                                          constant: 10);
        let leadingModes = NSLayoutConstraint(item: modes!,
                                              attribute: .leading,
                                              relatedBy: .equal,
                                              toItem: mapView,
                                              attribute: .leading,
                                              multiplier: 1,
                                              constant: 10);
        NSLayoutConstraint.activate([topModes, leadingModes]);
    }
    
    func setupMapMode() {
        mapMode = UISegmentedControl(items: [NSLocalizedString("Std", comment: "Std"),
                                             NSLocalizedString("Sat", comment: "Sat"),
                                             NSLocalizedString("Hyb", comment: "Hyb"),
                                             NSLocalizedString("Fly", comment: "Fly"),
                                             NSLocalizedString("HybFly", comment: "HybFly"),
                                             NSLocalizedString("Mute", comment: "Mute"),
                                             NSLocalizedString("OSM", comment: "OSM")
                                            ]);
        mapMode!.apportionsSegmentWidthsByContent = true;
        mapMode!.translatesAutoresizingMaskIntoConstraints = false;
        mapMode!.backgroundColor = UIColor(named: "modesColor");
        mapMode!.addTarget(self, action: #selector(mapModeChanged(_:)), for: .valueChanged);
        view.addSubview(mapMode!);
        let selected = UserDefaults.standard.integer(forKey: "mapMode");
        if mapMode!.numberOfSegments > selected && selected >= 0 {
            mapMode!.selectedSegmentIndex = selected;
        } else {
            mapMode!.selectedSegmentIndex = 0;
        }
        
        let bottomMapMode = NSLayoutConstraint(item: mapMode!,
                                               attribute: .bottom,
                                               relatedBy: .equal,
                                               toItem: mapView,
                                               attribute: .bottomMargin,
                                               multiplier: 1,
                                               constant: -30);
        let leadingMapMode = NSLayoutConstraint(item: mapMode!,
                                                attribute: .leading,
                                                relatedBy: .equal,
                                                toItem: mapView,
                                                attribute: .leading,
                                                multiplier: 1,
                                                constant: 10);
        NSLayoutConstraint.activate([bottomMapMode, leadingMapMode]);
    }
    
    func setupScaleView() {
        scaleView = MKScaleView(mapView: mapView);
        scaleView!.translatesAutoresizingMaskIntoConstraints = false;
        view.addSubview(scaleView!);
        
        let bottomScale = NSLayoutConstraint(item: scaleView!,
                                             attribute: .bottom,
                                             relatedBy: .equal,
                                             toItem: mapView,
                                             attribute: .bottomMargin,
                                             multiplier: 1,
                                             constant: -10);
        let leadingScale = NSLayoutConstraint(item: scaleView!,
                                              attribute: .centerXWithinMargins,
                                              relatedBy: .equal,
                                              toItem: mapView,
                                              attribute: .centerXWithinMargins,
                                              multiplier: 1,
                                              constant: 0);
        NSLayoutConstraint.activate([bottomScale, leadingScale]);
    }
    
    func updateMoveButton() {
        let locked = Settings.theLocked(inMOC: CoreData.sharedInstance().mainMOC);
        modes!.isEnabled = !locked;
        
        switch LocationManager.sharedInstance().monitoring {
        case .move: modes!.selectedSegmentIndex = 3;
        case .significant: modes!.selectedSegmentIndex = 2;
        case .manual: modes!.selectedSegmentIndex = 1;
        case .quiet: modes!.selectedSegmentIndex = 0;
        default: modes!.selectedSegmentIndex = 0;
        }
        
        for index in 0...modes!.numberOfSegments - 1  {
            var title = modes!.titleForSegment(at: index);
            if title != nil {
                if title!.hasSuffix("#") {
                    title!.remove(at: title!.index(before: title!.endIndex));
                }
                if title!.hasSuffix("!") {
                    title!.remove(at: title!.index(before: title!.endIndex));
                }
                modes!.setTitle(title!, forSegmentAt: index);
            }
        }
        
        let index = modes!.selectedSegmentIndex;
        var title = modes!.titleForSegment(at: index);
        if title != nil {
            if UserDefaults.standard.bool(forKey: "downgraded") {
                if title!.hasSuffix("!") {
                    title = title!.appending("!");
                }
            }
            if UserDefaults.standard.bool(forKey: "adapted") {
                if title!.hasSuffix("#") {
                    title = title!.appending("#");
                }
            }
            modes!.setTitle(title, forSegmentAt: index);
        }
    }
    
    func updateAccuracyButton() {
        let location = mapView.userLocation.location;
        if location != nil {
            accuracyButton.title = OwnTracksFormatter.accuracy(from: location!.horizontalAccuracy);
        } else {
            accuracyButton.title = "-";
        }
        actionButton.isEnabled = accuracyButton.title != "-";
    }
    
    func reloaded() {
        mapView.removeAnnotations(mapView.annotations);
        mapView.removeOverlays(mapView.overlays);

        let moc = CoreData.sharedInstance().mainMOC;
        let frFriends = Friend.fetchRequestAllNonStale(moc);
        frcFriends = NSFetchedResultsController(fetchRequest: frFriends,
                                                managedObjectContext: moc,
                                                sectionNameKeyPath: nil,
                                                cacheName: nil);
        frcFriends!.delegate = self;
        do {
            try frcFriends!.performFetch();
        } catch {
        }
        
        mapView.addAnnotations(frcFriends!.fetchedObjects!);
        
        let frRegions = NSFetchRequest<Region>(entityName: "Region");
        frRegions.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)];
        frcRegions = NSFetchedResultsController(fetchRequest: frRegions,
                                                managedObjectContext: moc,
                                                sectionNameKeyPath: nil,
                                                cacheName: nil);
        frcRegions!.delegate = self;
        do {
            try frcRegions!.performFetch();
        } catch {
        }
        
        let myself = Friend(topic: Settings.theGeneralTopic(inMOC: moc), in: moc);
        var regions: [Region] = [];
        for region in myself.hasRegions! {
            regions.append(region);
            if region.cLregion != nil {
                LocationManager.sharedInstance().start(region.cLregion!);
            }
        }
        mapView.addOverlays(regions);
        mapView.addAnnotations(regions);
        
        let frWaypoints = NSFetchRequest<Waypoint>(entityName: "Waypoint");
        frWaypoints.predicate = NSPredicate(format: "poi <> NULL");
        frWaypoints.sortDescriptors = [NSSortDescriptor(key: "tst", ascending: true)];
        frcWaypoints = NSFetchedResultsController(fetchRequest: frWaypoints,
                                                  managedObjectContext: moc,
                                                  sectionNameKeyPath: nil,
                                                  cacheName: nil);
        frcWaypoints!.delegate = self;
        do {
            try frcWaypoints!.performFetch();
        } catch {
        }
        mapView.addAnnotations(frcWaypoints!.fetchedObjects!);
        
        updateMoveButton();
    }
    
    func controller(_ controller: NSFetchedResultsController<any NSFetchRequestResult>, didChange anObject: Any, at indexPath: IndexPath?, for type: NSFetchedResultsChangeType, newIndexPath: IndexPath?) {
        DispatchQueue.main.async {
            if anObject is Friend {
                let friend = anObject as! Friend;
                let waypoint = friend.newestWaypoint;
                if waypoint != nil {
                    switch type {
                    case .insert:
                        if waypoint!.lat?.doubleValue != 0.0 && waypoint!.lon?.doubleValue != 0.0 {
                            self.mapView.addAnnotation(friend);
                        }
                    case .delete:
                        self.mapView.removeOverlay(friend);
                        self.mapView.removeAnnotation(friend);
                    case .update, .move:
                        self.mapView.removeOverlay(friend);
                        self.mapView.removeAnnotation(friend);
                        if waypoint!.lat?.doubleValue != 0.0 && waypoint!.lon?.doubleValue != 0.0 {
                            self.mapView.addAnnotation(friend);
                        }
                    @unknown default:
                        let logger = Logger(subsystem: "org.mqttitude", category: "MQTTitude");
                        logger.error("default case frcFriends");
                    }
                }
            } else if anObject is Region {
                let region = anObject as! Region;
                switch type {
                case .insert:
                    self.mapView.addAnnotation(region);
                    self.mapView.addOverlay(region);
                case .delete:
                    self.mapView.removeAnnotation(region);
                    self.mapView.removeOverlay(region);
                case .update, .move:
                    self.mapView.removeAnnotation(region);
                    self.mapView.removeOverlay(region);
                    self.mapView.addAnnotation(region);
                    self.mapView.addOverlay(region);
                @unknown default:
                    let logger = Logger(subsystem: "org.mqttitude", category: "MQTTitude");
                    logger.error("default case frcRegions");
                    
                }
            } else if anObject is Waypoint {
                let waypoint = anObject as! Waypoint;
                switch type {
                case .insert:
                    self.mapView.addAnnotation(waypoint);
                case .delete:
                    self.mapView.removeAnnotation(waypoint);
                case .update, .move:
                    self.mapView.removeAnnotation(waypoint);
                    self.mapView.addAnnotation(waypoint);
                @unknown default:
                    let logger = Logger(subsystem: "org.mqttitude", category: "MQTTitude");
                    logger.error("default case frcWaypoints");
                }
            }
        }
    }
    
    @discardableResult
    func noMap() -> Int {
        let locked = Settings.theLocked(inMOC: CoreData.sharedInstance().mainMOC);
        askForMapButton.isEnabled = !locked;
        
        let noMap = UserDefaults.standard.integer(forKey: "noMap");
        if noMap > 0 {
            mapView.showsUserLocation = true;
            mapView.isZoomEnabled = true;
            mapView.isScrollEnabled = true;
            mapView.isPitchEnabled = true;
            mapView.isRotateEnabled = true;
            
            if trackingButton == nil {
                trackingButton = MKUserTrackingButton(mapView: mapView);
                trackingButton!.translatesAutoresizingMaskIntoConstraints = false;
                view.addSubview(trackingButton!);
                let topTracking = NSLayoutConstraint(item: trackingButton!,
                                                     attribute: .top,
                                                     relatedBy: .equal,
                                                     toItem: modes!,
                                                     attribute: .bottom,
                                                     multiplier: 1,
                                                     constant: 8);
                let leadingTracking = NSLayoutConstraint(item: trackingButton!,
                                                         attribute: .leading,
                                                         relatedBy: .equal,
                                                         toItem: mapView,
                                                         attribute: .leading,
                                                         multiplier: 1,
                                                         constant: 10);
                NSLayoutConstraint.activate([topTracking, leadingTracking]);
            }
            
            if #available(iOS 26.0, *) {
                privacyButton.badge = nil
            } else {
                // Fallback on earlier versions
            }
        } else {
            mapView.showsUserLocation = true;
            mapView.isZoomEnabled = false;
            mapView.isScrollEnabled = false;
            mapView.isPitchEnabled = false;
            mapView.isRotateEnabled = false;
            
            if trackingButton != nil {
                trackingButton!.removeFromSuperview();
                trackingButton = nil;
            }
            
            if #available(iOS 26.0, *) {
                privacyButton.badge = UIBarButtonItem.Badge.indicator();
            } else {
                // Fallback on earlier versions
            }
            
        }
        
        return noMap;
    }
    
    func setCenter(annotation: MKAnnotation) {
        if noMap() > 0 {
            let coordinate = annotation.coordinate;
            mapView.setVisibleMapRect(centeredRect(for: coordinate), animated: true);
            mapView.userTrackingMode = .none;
        }
    }
    
    func centeredRect(for coordinate: CLLocationCoordinate2D) -> MKMapRect {
        let initialRadius = 600.0;
        let r = initialRadius * MKMapPointsPerMeterAtLatitude(coordinate.latitude);
        var rect : MKMapRect = .null;
        rect.origin = MKMapPoint(coordinate);
        rect.origin.x -= r;
        rect.origin.y -= r;
        rect.size.width = r * 2.0;
        rect.size.height = r * 2.0;
        return rect;
    }
    
    @IBAction func modesChanged(_ sender: UISegmentedControl) {
        var monitoring: LocationMonitoring = .quiet;
        
        switch sender.selectedSegmentIndex {
        case 3: monitoring = .move;
        case 2: monitoring = .significant;
        case 1: monitoring = .manual
        case 0: monitoring = .quiet;
        default: monitoring = .quiet;
        }
        
        if monitoring != LocationManager.sharedInstance().monitoring {
            LocationManager.sharedInstance().monitoring = monitoring;
            UserDefaults.standard.set(false, forKey: "downgraded");
            UserDefaults.standard.set(false, forKey: "adapted");
            Settings.setInt(Int32(monitoring.rawValue),
                            forKey: "monitoring_preference",
                            inMOC: CoreData.sharedInstance().mainMOC);
            CoreData.sharedInstance().sync(CoreData.sharedInstance().mainMOC);
            updateMoveButton();
        }
    }
    
    @IBAction func mapModeChanged(_ sender: UISegmentedControl) {
        if osmOverlay != nil {
            mapView.removeOverlay(osmOverlay!);
            osmOverlay = nil;
        }
        if osmCopyright != nil {
            osmCopyright!.removeFromSuperview();
            osmCopyright = nil;
        }
        for view in mapView.subviews {
            if NSStringFromClass(type(of: view)) == "MKAttributionLabel" {
                view.isHidden = false;
            }
        }
        
        switch sender.selectedSegmentIndex {
        case 6:
            mapView.mapType = .standard;
            var osmTemplateString = Settings.string(forKey: "osmtemplate_preference",
                                                    inMOC: CoreData.sharedInstance().mainMOC);
            if osmTemplateString == nil || osmTemplateString!.isEmpty {
                osmTemplateString = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
            }
            
            var osmCopyrightString = Settings.string(forKey: "osmcopyright_preference",
                                                     inMOC: CoreData.sharedInstance().mainMOC);
            if osmCopyrightString == nil || osmCopyrightString!.isEmpty {
                osmCopyrightString = "© OpenStreetMap contributors";
            }
            
            osmOverlay = MKTileOverlay(urlTemplate: osmTemplateString);
            osmOverlay!.canReplaceMapContent = true;
            osmRenderer = MKTileOverlayRenderer(tileOverlay: osmOverlay!);
            mapView.insertOverlay(osmOverlay!, at: 0);
            
            for view in mapView.subviews {
                if NSStringFromClass(type(of: view)) == "MKAttributionLabel" {
                    view.isHidden = true;
                }
            }
            
            osmCopyright = UITextField();
            osmCopyright!.text = osmCopyrightString!;
            osmCopyright!.font = UIFont.systemFont(ofSize: UIFont.smallSystemFontSize);
            osmCopyright!.isEnabled = false;
            osmCopyright!.translatesAutoresizingMaskIntoConstraints = false;
            view.addSubview(osmCopyright!);
            
            let bottomCopyright = NSLayoutConstraint(item: osmCopyright!,
                                                     attribute: .bottom,
                                                     relatedBy: .equal,
                                                     toItem: mapView,
                                                     attribute: .bottomMargin,
                                                     multiplier: 1,
                                                     constant: 0);
            let trailingCopyright = NSLayoutConstraint(item: osmCopyright!,
                                                       attribute: .trailing,
                                                       relatedBy: .equal,
                                                       toItem: mapView,
                                                       attribute: .trailingMargin,
                                                       multiplier: 1,
                                                       constant: 0);
            NSLayoutConstraint.activate([bottomCopyright, trailingCopyright]);
            
        case 5: mapView.mapType = .mutedStandard;
        case 4: mapView.mapType = .hybridFlyover;
        case 3: mapView.mapType = .satelliteFlyover;
        case 2: mapView.mapType = .hybrid;
        case 1: mapView.mapType = .satellite;
        case 0: mapView.mapType = .standard;
        default: mapView.mapType = .standard;
        }
        
        mapView.setNeedsLayout();
        mapView.setNeedsDisplay();
        
        UserDefaults.standard.set(sender.selectedSegmentIndex, forKey: "mapMode");
    }
    
    @IBAction func askForMap(_ sender: UIBarButtonItem) {
        let ac = UIAlertController(title: NSLocalizedString("Map Interaction",
                                                            comment: "Title map interaction"),
                                   message: NSLocalizedString("Do you want the map to allow interaction? If you choose yes, the map provider may analyze your tile requests",
                                                              comment: "Message map interaction"),
                                   preferredStyle: .alert);
        let yes = UIAlertAction(title: NSLocalizedString("Yes",
                                                         comment: "Yes button title"),
                                style: .default) { _ in
            UserDefaults.standard.set(1, forKey: "noMap");
            self.noMap();
            self.askForRevgeo();
        }
        let no = UIAlertAction(title: NSLocalizedString("No",
                                                        comment: "No button title"),
                               style: .destructive) { _ in
            UserDefaults.standard.set(-1, forKey: "noMap");
            self.noMap();
            self.askForRevgeo();
        }
        
        ac.addAction(yes);
        ac.addAction(no);
        present(ac, animated: true);
    }
    
    func askForRevgeo() {
        let ac = UIAlertController(title: NSLocalizedString("Reverse Geocoding Address Resolution",
                                                            comment: "Title Revgeo"),
                                   message: NSLocalizedString("Do you want to resolve adresses? If you choose yes, the geocoding provider may analyze your requests",
                                                              comment: "Message Revgeo"),
                                   preferredStyle: .alert);
        
        let yes = UIAlertAction(title: NSLocalizedString("Yes",
                                                         comment: "Yes button title"),
                                style: .default) { _ in
            UserDefaults.standard.set(1, forKey: "noRevgeo");
        }
        let no = UIAlertAction(title: NSLocalizedString("No",
                                                        comment: "No button title"),
                               style: .destructive) { _ in
            UserDefaults.standard.set(-1, forKey: "noRevGeo");
        }
        
        ac.addAction(yes);
        ac.addAction(no);
        present(ac, animated: true);
    }
    
    @IBAction func longPress(_ sender: UILongPressGestureRecognizer) {
        if Settings.theLocked(inMOC: CoreData.sharedInstance().mainMOC) {
            return;
        }
        
        if sender.state == .began {
            let myself = Friend(topic: Settings.theGeneralTopic(inMOC: CoreData.sharedInstance().mainMOC),
                                in: CoreData.sharedInstance().mainMOC);
            let rid = Region.newRid();
            OwnTracking.sharedInstance().addRegion(for: rid,
                                                   friend: myself,
                                                   name: "Center-\(rid)",
                                                   tst: Date.now,
                                                   uuid: nil,
                                                   major: 0,
                                                   minor: 0,
                                                   radius: 0,
                                                   lat: mapView.centerCoordinate.latitude,
                                                   lon: mapView.centerCoordinate.longitude);
            NavigationController.alert(title: NSLocalizedString("Region",
                                                                comment: "Header of an alert message regarding circular region"),
                                       message: NSLocalizedString("created at center of map",
                                                                  comment: "content of an alert message regarding circular region"),
                                       dismissAfter: 1);
        }
    }
    
    @IBAction func actionPressed(_ sender: UIBarButtonItem) {
        let ac = UIAlertController(title: NSLocalizedString("Choose action", comment: "Choose action title"),
                                   message: nil,
                                   preferredStyle: .alert);
        let sendNow = UIAlertAction(title: NSLocalizedString("Send location now",
                                                             comment: "Send location now"),
                                    style: .default) { _ in
            self.sendNow(poi: nil, image: nil, imageName: nil);
        }
        let setPoi = UIAlertAction(title: NSLocalizedString("Set POI", comment: "Set POI button"),
                                   style: .default) { _ in
            self.setPOI();
        }
        let setPoiWithImage = UIAlertAction(title: NSLocalizedString("Set POI with image",
                                                                     comment: "Set POI with image button"),
                                            style: .default) { _ in
            self.setPOIWithImage();
        }
        let setTag = UIAlertAction(title: NSLocalizedString("Set tag", comment: "Set tag button"),
                                   style: .default) { _ in
            self.setTag();
        }
        let cancel = UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                                   style: .cancel, handler: nil);
        ac.addAction(sendNow);
        ac.addAction(setPoi);
        ac.addAction(setPoiWithImage);
        ac.addAction(setTag);
        ac.addAction(cancel);
        present(ac, animated: true, completion: nil);
    }
    
    func sendNow(poi: String?, image: Data?, imageName: String?) {
        if !Settings.validIds(inMOC: CoreData.sharedInstance().mainMOC) {
            NavigationController.alert(title: "Settings",
                                       message: NSLocalizedString("To publish your location userID and deviceID must be set",
                                                                  comment: "Warning displayed if necessary settings are missing"));
            return;
        }

        let location = mapView.userLocation.location;
        if location == nil ||
            !CLLocationCoordinate2DIsValid(location!.coordinate) ||
            (location!.coordinate.latitude == 0.0 && location!.coordinate.longitude == 0.0) {
            NavigationController.alert(title: NSLocalizedString("Location",
                                                                comment: "Header of an alert message regarding a location"),
                                       message: NSLocalizedString("No location available",
                                                                  comment: "Warning displayed if not location available"));
            return;
        }
        
        let ignoreInaccurateLocations = Settings.int(forKey: "ignoreinaccuratelocations_preference",
                                                     inMOC: CoreData.sharedInstance().mainMOC);
        if ignoreInaccurateLocations != 0 && Int32(location!.horizontalAccuracy) > ignoreInaccurateLocations {
            NavigationController.alert(title: NSLocalizedString("Location",
                                                                comment: "Header of an alert message regarding a location"),
                                       message: NSLocalizedString("Inaccurate or old location information",
                                                                  comment: "Warning displayed if location is inaccurate or old"));
            return;
        }
        
        let ad = UIApplication.shared.delegate as! OwnTracksAppDelegate;
        if ad.sendNow(location!, withPOI: poi, withImage: image, withImageName: imageName) {
            NavigationController.alert(title: NSLocalizedString("Location",
                                                                comment: "Header of an alert message regarding a location"),
                                       message: NSLocalizedString("publish queued on user request",
                                                                  comment: "content of an alert message regarding user publish"),
                                       dismissAfter: 1);

        } else {
            NavigationController.alert(title: NSLocalizedString("Location",
                                                                comment: "Header of an alert message regarding a location"),
                                       message: NSLocalizedString("publish queued on user request",
                                                                  comment: "content of an alert message regarding user publish"));

        }

    }
    
    func setPOI() {
        let ac = UIAlertController(title: NSLocalizedString("Set POI", comment: "Set POI title"),
                                   message: nil,
                                   preferredStyle: .alert);
        let send = UIAlertAction(title: NSLocalizedString("Send",
                                                          comment: "Send button title"),
                                 style: .default) { _ in
            self.sendNow(poi: ac.textFields![0].text, image: nil, imageName: nil);
        }
        let cancel = UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                                   style: .cancel, handler: nil);
        ac.addTextField { textField in
            textField.text = nil;
        }
        ac.addAction(send);
        ac.addAction(cancel);
        present(ac, animated: true);
    }
    
    func setPOIWithImage() {
        // 改造版: この画面は削った
    }
    
    func setTag() {
        let ac = UIAlertController(title: NSLocalizedString("Set Tag", comment: "Set Tag title"),
                                   message: nil,
                                   preferredStyle: .alert);
        let send = UIAlertAction(title: NSLocalizedString("Send",
                                                          comment: "Send button title"),
                                 style: .default) { _ in
            if ac.textFields![0].text == nil || ac.textFields![0].text!.isEmpty {
                UserDefaults.standard.set(nil, forKey: "tag");
            } else {
                UserDefaults.standard.set(ac.textFields![0].text, forKey: "tag");
            }
            self.sendNow(poi: nil, image: nil, imageName: nil);
        }
        let remove = UIAlertAction(title: NSLocalizedString("Remove", comment: "Remove button title"),
                                   style: .default) { _ in
            UserDefaults.standard.set(nil, forKey: "tag");
        }
        let cancel = UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                                   style: .cancel, handler: nil);
        ac.addTextField { textField in
            textField.text = UserDefaults.standard.string(forKey: "tag");
        }
        ac.addAction(send);
        ac.addAction(remove);
        ac.addAction(cancel);
        present(ac, animated: true);

    }
    
    @IBAction func attachPhoto(_ segue: UIStoryboardSegue) {
        // 改造版: この画面は削った
    }
    
    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        if overlay is Friend {
            let friend = overlay as! Friend;
            let renderer = MKPolylineRenderer(polyline: friend.polyLine);
            renderer.lineWidth = 3;
            renderer.strokeColor = UIColor(named: "trackColor");
            return renderer;
        } else if overlay is Region {
            let region = overlay as! Region;
            if region.cLregion != nil && region.cLregion is CLCircularRegion {
                let renderer = MKCircleRenderer(circle: region.circle);
                if region.cLregion != nil && region.cLregion!.isFollow() {
                    renderer.fillColor = UIColor(named: "followColor");
                } else {
                    if LocationManager.sharedInstance().insideCircularRegion(region.name ?? "") {
                        renderer.fillColor = UIColor(named: "insideColor");
                    } else {
                        renderer.fillColor = UIColor(named: "outsideColor");
                    }
                }
                return renderer;
            } else {
                return MKOverlayRenderer(overlay: overlay);
            }
        } else if overlay is MKTileOverlay {
            return self.osmRenderer!
        } else {
            return MKOverlayRenderer(overlay: overlay);
        }
    }
    
    func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
        if newState == .none {
            let annotations = mapView.annotations;
            mapView.removeAnnotations(annotations);
            mapView.addAnnotations(annotations);
        }
    }
    
    func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        if !initialCenter {
            initialCenter = true;
            if userLocation.location != nil {
                mapView.setCenter(userLocation.location!.coordinate, animated: true);
            }
        }
    }
    
    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        if annotation is MKUserLocation {
            return nil;
        } else if annotation is Friend {
            let friendReuse = "Annotation_picture";
            let friend = annotation as! Friend;
            let waypoint = friend.newestWaypoint;
            let annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: friendReuse);
            var friendAnnotationV: FriendAnnotationV;
            if annotationView != nil {
                friendAnnotationV = annotationView as! FriendAnnotationV;
            } else {
                friendAnnotationV = FriendAnnotationV(annotation: friend, reuseIdentifier: friendReuse)
            }
            friendAnnotationV.displayPriority = .required;
            friendAnnotationV.zPriority = .defaultSelected;
            friendAnnotationV.canShowCallout = true;
            friendAnnotationV.rightCalloutAccessoryView = UIButton(type: .detailDisclosure);
            
            friendAnnotationV.personImage = UIImage(data: friend.image ?? Data());
            friendAnnotationV.tid = friend.effectiveTid;
            friendAnnotationV.speed = waypoint?.vel?.doubleValue ?? 0;
            friendAnnotationV.course = waypoint?.cog?.doubleValue ?? 0;
            friendAnnotationV.me = friend.topic == Settings.theGeneralTopic(inMOC: CoreData.sharedInstance().mainMOC);
            
            friendAnnotationV.setNeedsDisplay();
            return friendAnnotationV;
        } else if annotation is Waypoint {
            let waypoint = annotation as! Waypoint;
            var annotationView: MKAnnotationView?;
            if waypoint.image != nil {
                let waypointImageReuse = "Annotation_image";
                annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: waypointImageReuse);
                var pAV: PhotoAnnotationV;
                if annotationView != nil {
                    pAV = annotationView as! PhotoAnnotationV;
                } else {
                    pAV = PhotoAnnotationV(annotation: waypoint, reuseIdentifier: waypointImageReuse);
                }
                pAV.displayPriority = .required;
                pAV.poiImage = UIImage(data: waypoint.image ?? Data());
                pAV.canShowCallout = true;
                pAV.rightCalloutAccessoryView = UIButton(type: .detailDisclosure);
                annotationView = pAV;
            } else {
                let waypointPoiReuse = "Annotation_poi";
                annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: waypointPoiReuse);
                var mAV: MKMarkerAnnotationView;
                if annotationView != nil {
                    mAV = annotationView as! MKMarkerAnnotationView;
                } else {
                    mAV = MKMarkerAnnotationView(annotation: waypoint, reuseIdentifier: waypointPoiReuse);
                }
                mAV.displayPriority = .required;
                mAV.canShowCallout = true;
                mAV.rightCalloutAccessoryView = UIButton(type: .detailDisclosure);
                annotationView = mAV;
            }
            annotationView?.setNeedsDisplay();
            return annotationView;
        } else if annotation is Region {
            let region = annotation as! Region;
            if region.cLregion is CLBeaconRegion {
                let regionBeaconReuse = "Annotation_Beacon";
                let annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: regionBeaconReuse);
                var mAV: MKMarkerAnnotationView;
                if annotationView != nil {
                    mAV = annotationView as! MKMarkerAnnotationView;
                } else {
                    mAV = MKMarkerAnnotationView(annotation: region, reuseIdentifier: regionBeaconReuse);
                }
                mAV.displayPriority = .required;
                if LocationManager.sharedInstance().insideBeaconRegion(region.name ?? "") {
                    mAV.markerTintColor = UIColor(named: "beaconHotColor");
                    mAV.glyphImage = UIImage(named: "iBeaconHot");
                } else {
                    mAV.markerTintColor = UIColor(named: "beaconColdColor");
                    mAV.glyphImage = UIImage(named: "iBeaconCold");
                }
                mAV.isDraggable = true;
                mAV.canShowCallout = true;
                mAV.rightCalloutAccessoryView = UIButton(type: .detailDisclosure);
                mAV.setNeedsDisplay();
                return mAV;
            } else {
                if region.cLregion != nil && region.cLregion!.isFollow() {
                    return nil;
                }
                let regionCircleReuse = "Annotation_circle";
                let annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: regionCircleReuse);
                var mAV: MKMarkerAnnotationView;
                if annotationView != nil {
                    mAV = annotationView as! MKMarkerAnnotationView;
                } else {
                    mAV = MKMarkerAnnotationView(annotation: region, reuseIdentifier: regionCircleReuse);
                }
                mAV.displayPriority = .required;
                mAV.markerTintColor = UIColor(named: "pinColor");
                mAV.isDraggable = true;
                mAV.canShowCallout = true;
                mAV.rightCalloutAccessoryView = UIButton(type: .detailDisclosure);
                mAV.setNeedsDisplay();
                return mAV;
            }
        }
        return nil;
    }
    
    func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
        if control == view.rightCalloutAccessoryView {
            if view.annotation is Friend {
                performSegue(withIdentifier: "showWaypointFromMap", sender: view);
            } else if view.annotation is Region {
                performSegue(withIdentifier: "showRegionFromMap", sender: view);
            } else if view.annotation is Waypoint {
                performSegue(withIdentifier: "showWaypointFromMap", sender: view);
            }
        }
    }
    
    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        if view.annotation is Friend {
            let friend = view.annotation as! Friend;
            mapView.addOverlay(friend);
        }
    }
    
    func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
        if view.annotation is Friend {
            let friend = view.annotation as! Friend;
            mapView.removeOverlay(friend);
        }
    }
}
