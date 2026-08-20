//
//  MediaTrack.swift
//  RateSync
//
//  Created by Vincent Neo on 1/5/22.
//

import Foundation
import MediaRemoteAdapter

struct MediaTrack: Equatable, Hashable {
    
    let isMusicApp: Bool
    let id: String?
    let bundleIdentifier: String?
    let pid: pid_t?
    
    let title: String?
    let album: String?
    let artist: String?
    let trackNumber: String?
    
    init(trackInfo: TrackInfo) {
        let payload = trackInfo.payload
        self.id = payload.uniqueIdentifier
        self.bundleIdentifier = payload.bundleIdentifier
        self.pid = payload.PID
        self.isMusicApp = (payload.bundleIdentifier == Defaults.appleMusicBundleIdentifier)
        self.title = payload.title
        self.album = payload.album
        self.artist = payload.artist
        self.trackNumber = nil
    }
}
