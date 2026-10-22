import Foundation

// System-wide Now Playing access, hosted by Apple's osascript on macOS 15.4+.
// MediaRemote is private: missing selectors, fields or replies always fail closed.
// Never return titles, artists, artwork or other media content to the app's logs.
enum DictationMediaScript {
    static let source = #"""
    function setup() {
        ObjC.import('Foundation');
        if (!$.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load) {
            throw new Error('unavailable');
        }
    }

    function snapshot() {
        const request = $.NSClassFromString('MRNowPlayingRequest');
        const path = request.localNowPlayingPlayerPath;
        const item = request.localNowPlayingItem;
        if (path.isNil() || item.isNil()) return null;
        const info = item.nowPlayingInfo;
        const value = key => ObjC.unwrap(info.objectForKey(key));
        const stamp = value('kMRMediaRemoteNowPlayingInfoTimestamp');
        const state = {
            path: ObjC.unwrap(path.description),
            item: value('kMRMediaRemoteNowPlayingInfoContentItemIdentifier'),
            rate: value('kMRMediaRemoteNowPlayingInfoPlaybackRate'),
            position: value('kMRMediaRemoteNowPlayingInfoElapsedTime'),
            stamp: stamp instanceof Date ? stamp.getTime() : null
        };
        return valid(state) ? state : null;
    }

    function valid(state) {
        return state !== null && typeof state.path === 'string' && state.path.length > 0 &&
            typeof state.item === 'string' && state.item.length > 0 &&
            typeof state.rate === 'number' && isFinite(state.rate) && state.rate >= 0 &&
            typeof state.position === 'number' && isFinite(state.position) && state.position >= 0 &&
            typeof state.stamp === 'number' && isFinite(state.stamp);
    }

    function sameItem(left, right) {
        return valid(left) && valid(right) && left.path === right.path && left.item === right.item;
    }

    function send(command) {
        const controller = $.NSClassFromString('MRNowPlayingController').localRouteController;
        controller.sendCommandOptionsCompletion(command, $.NSDictionary.alloc.init, null);
    }

    function wait() {
        $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.025));
    }

    function pause() {
        const before = snapshot();
        if (!valid(before) || before.rate <= 0) return {status: 'ignored'};
        send(1); // MediaRemote Pause, never toggle.
        for (let attempt = 0; attempt < 40; attempt++) {
            wait();
            const after = snapshot();
            if (!sameItem(before, after)) return {status: 'changed'};
            if (after.rate === 0 && after.stamp !== before.stamp) {
                return {status: 'paused', receipt: after};
            }
        }
        return {status: 'unconfirmed'};
    }

    function resume(receipt) {
        const current = snapshot();
        // A new update, seek, player, process or item forfeits ownership.
        if (!sameItem(receipt, current) || receipt.rate !== 0 || current.rate !== 0 ||
            receipt.stamp !== current.stamp || receipt.position !== current.position) {
            return {status: 'changed'};
        }
        send(0); // MediaRemote Play, only for the unchanged pause we confirmed.
        for (let attempt = 0; attempt < 40; attempt++) {
            wait();
            const after = snapshot();
            if (!sameItem(receipt, after)) return {status: 'changed'};
            if (after.rate > 0) return {status: 'resumed'};
        }
        return {status: 'unconfirmed'};
    }

    function run(arguments) {
        try {
            setup();
            if (arguments[0] === 'pause') return JSON.stringify(pause());
            if (arguments[0] === 'resume') return JSON.stringify(resume(JSON.parse(arguments[1])));
        } catch (_) {
            return JSON.stringify({status: 'unavailable'});
        }
        return JSON.stringify({status: 'unavailable'});
    }
    """#
}
