//
//  ViewController.swift
//  OwnTracks
//
//  Created by Christoph Krey on 19.03.26.
//  Copyright © 2026 OwnTracks. All rights reserved.
//

import Foundation
import UIKit
import CoreLocation
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

// 改造R4: Appleの地図は削除。モード切替・Webの地図（/map?src=x）・今すぐ送る・精度の表示だけを持つ
class ViewController: UIViewController {
    @IBOutlet weak var actionButton: UIBarButtonItem!;
    @IBOutlet weak var accuracyButton: UIBarButtonItem!;

    var modes: UISegmentedControl?;
    var webMap: WKWebView?;

    override func viewDidLoad() {
        super.viewDidLoad();
        setupModes();
        showWebMap();
        LocationManager.sharedInstance().addObserver(self, forKeyPath: "monitoring", options: [.initial, .new], context: nil);
        NotificationCenter.default.addObserver(forName: NSNotification.Name("reload"), object: nil,
                                               queue: OperationQueue.main) { _ in self.updateAccuracyButton(); }
        updateAccuracyButton();
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated);
        updateAccuracyButton();
        if webMap?.url != nil { webMap?.reload(); }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "monitoring" {
            DispatchQueue.main.async { self.updateMoveButton(); }
        }
    }

    func setupModes() {
        let m = UISegmentedControl(items: [NSLocalizedString("Quiet", comment: "Quiet"),
                                           NSLocalizedString("Manual", comment: "Manual"),
                                           NSLocalizedString("Significant", comment: "Significant"),
                                           NSLocalizedString("Move", comment: "Move")]);
        m.apportionsSegmentWidthsByContent = true;
        m.translatesAutoresizingMaskIntoConstraints = false;
        m.backgroundColor = UIColor(named: "modesColor");
        m.addTarget(self, action: #selector(modesChanged(_:)), for: .valueChanged);
        view.addSubview(m);
        NSLayoutConstraint.activate([
            m.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            m.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
        ]);
        modes = m;
    }

    // モード切替の下に、送信先URL（…/pubx）と同じホストの/map?src=xを表示する
    func showWebMap() {
        let web = WKWebView(frame: .zero);
        web.navigationDelegate = self;
        web.translatesAutoresizingMaskIntoConstraints = false;
        view.addSubview(web);
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.topAnchor.constraint(equalTo: modes!.bottomAnchor, constant: 6),
            web.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ]);
        webMap = web;
        let moc = CoreData.sharedInstance().mainMOC;
        guard let s = Settings.string(forKey: "url_preference", inMOC: moc) as String?,
              var c = URLComponents(string: s) else { return; }
        c.path = "/map";
        c.query = "src=x";
        if let url = c.url { web.load(URLRequest(url: url)); }
    }

    func updateMoveButton() {
        guard let m = modes else { return; }
        m.isEnabled = !Settings.theLocked(inMOC: CoreData.sharedInstance().mainMOC);
        switch LocationManager.sharedInstance().monitoring {
        case .move: m.selectedSegmentIndex = 3;
        case .significant: m.selectedSegmentIndex = 2;
        case .manual: m.selectedSegmentIndex = 1;
        default: m.selectedSegmentIndex = 0;
        }
    }

    func updateAccuracyButton() {
        let location = LocationManager.sharedInstance().location;
        accuracyButton.title = CLLocationCoordinate2DIsValid(location.coordinate) && location.horizontalAccuracy >= 0
            ? OwnTracksFormatter.accuracy(from: location.horizontalAccuracy) : "-";
        actionButton.isEnabled = accuracyButton.title != "-";
    }

    @objc func modesChanged(_ sender: UISegmentedControl) {
        var monitoring: LocationMonitoring = .quiet;
        switch sender.selectedSegmentIndex {
        case 3: monitoring = .move;
        case 2: monitoring = .significant;
        case 1: monitoring = .manual;
        default: monitoring = .quiet;
        }
        if monitoring != LocationManager.sharedInstance().monitoring {
            LocationManager.sharedInstance().monitoring = monitoring;
            UserDefaults.standard.set(false, forKey: "downgraded");
            UserDefaults.standard.set(false, forKey: "adapted");
            Settings.setInt(Int32(monitoring.rawValue), forKey: "monitoring_preference",
                            inMOC: CoreData.sharedInstance().mainMOC);
            CoreData.sharedInstance().sync(CoreData.sharedInstance().mainMOC);
            updateMoveButton();
        }
    }

    // 右上のボタン: 今の位置をすぐ送る
    @IBAction func actionPressed(_ sender: UIBarButtonItem) {
        let location = LocationManager.sharedInstance().location;
        guard Settings.validIds(inMOC: CoreData.sharedInstance().mainMOC),
              CLLocationCoordinate2DIsValid(location.coordinate),
              let ad = UIApplication.shared.delegate as? OwnTracksAppDelegate else {
            NavigationController.alert(title: "Location", message: "No location available");
            return;
        }
        _ = ad.sendNow(location, withPOI: nil, withImage: nil, withImageName: nil);
        NavigationController.alert(title: "Location", message: "publish queued on user request", dismissAfter: 1);
    }
}
