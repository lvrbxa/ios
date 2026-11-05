//
//  SceneDelegate.swift
//  OwnTracks
//
//  Created by Christoph Krey on 28/07/2026.
//  Copyright © 2026 OwnTracks. All rights reserved.
//

import Foundation

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func sceneDidBecomeActive(_ scene: UIScene) {
        let ad = UIApplication.shared.delegate as! OwnTracksAppDelegate;
        ad.appDidBecomeActive();
    }
    
    func sceneWillResignActive(_ scene: UIScene) {
        let ad = UIApplication.shared.delegate as! OwnTracksAppDelegate;
        ad.appWillResignActive();
    }
    
    // 改造mod9: ホーム画面のショートカット（UIApplicationDelegate側はiOS 26で非推奨）
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            let ad = UIApplication.shared.delegate as! OwnTracksAppDelegate;
            _ = ad.perform(item);
        }
        for urlContext in connectionOptions.urlContexts {
            let ad = UIApplication.shared.delegate as! OwnTracksAppDelegate;
            ad.open(urlContext.url);
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        let ad = UIApplication.shared.delegate as! OwnTracksAppDelegate;
        completionHandler(ad.perform(shortcutItem));
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
    }
    
    func sceneDidEnterBackground(_ scene: UIScene) {
        let ad = UIApplication.shared.delegate as! OwnTracksAppDelegate;
        ad.applicationDidEnterBackground(UIApplication.shared);
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for urlContext in URLContexts {
            let url = urlContext.url
            let ad = UIApplication.shared.delegate as! OwnTracksAppDelegate;
            ad.open(url);
        }
    }
}
