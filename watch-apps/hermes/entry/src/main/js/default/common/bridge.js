// JSON messaging with HuaSideload on the iPhone (a trimmed-down Huawei Wear Engine client).
// Messages look like {"t": type, ...}; on the phone WatchFeature.handle(_:from:) receives them.
//
// Important:
//  - '@system.wearengine' does not exist in the OpenHarmony compiler; importing it crashes the app at launch.
//    So it is loaded at runtime with requireModule, falling back to FeatureAbility.
//  - Starting the connection on the app's first page right at launch freezes the watch: show a plain
//    splash page first (pages/index), then call start() on the real page.
//  - Keep each message under ~1 KB.
var PHONE_PACKAGE = '__HUASIDELOAD_PHONE_PACKAGE__';   // build-watch-app.sh replaces this with the iPhone app's bundle ID
var PHONE_FINGERPRINT = 'CA612C488CBB19EE1601EAFFFE084ED6AC674AF264A861D9101CF1A3A191693E';   // WatchAppBridge.phoneFingerprint
var STEP_DELAY = 50;

var wearengine = null;
var api = null;
var ready = false;
var starting = false;
var startupReport = null;
var listener = null;
var queue = [];

function noop() {}

function receive(data) {
    if (!data || data.isRegister || data.isFileType || !listener) {
        return;
    }
    var message;
    try {
        message = JSON.parse(typeof data === 'string' ? data : data.message);
    } catch (e) {
        return;
    }
    if (message && message.t) {
        listener(message);
    }
}

function later(fn) {
    setTimeout(fn, STEP_DELAY);
}

function deliver(item) {
    try {
        api.sendMsg({
            deviceId: 'remote',
            bundleName: PHONE_PACKAGE,
            abilityName: '',
            message: JSON.stringify(item.message),
            success: function () {
                if (item.done) {
                    item.done(true);
                }
            },
            fail: function () {
                if (item.done) {
                    item.done(false);
                }
            }
        });
    } catch (e) {
        if (item.done) {
            item.done(false);
        }
    }
}

// Short pauses between the steps: the screen is drawn first, and if the watch hangs in a call you can see which one
function start(report) {
    report = report || noop;
    if (ready) {
        report('');
        return;
    }
    startupReport = report;
    if (starting) {
        return;
    }
    starting = true;
    later(function () {
        try {
            wearengine = requireModule('@system.wearengine');
        } catch (e) {
            wearengine = null;
        }
        var version = 0;
        if (wearengine && wearengine.getWearEngineVersion) {
            try {
                wearengine.getWearEngineVersion({
                    sdkVersion: '3',
                    complete: function (text) {
                        var parts = String(text || '').split('.');
                        version = parseInt(parts[parts.length - 1], 10) || 0;
                    }
                });
            } catch (e) {
                startupReport('version unknown');
            }
        }
        later(function () {
            if (wearengine && wearengine.setPackageName) {
                try {
                    wearengine.setPackageName({ appName: PHONE_PACKAGE, complete: noop, fail: noop });
                    wearengine.setFingerprint({ appName: PHONE_PACKAGE, appCert: PHONE_FINGERPRINT, complete: noop, fail: noop });
                } catch (e) {
                    startupReport('could not set package');
                }
            }
            later(function () {
                api = version >= 401 && wearengine ? wearengine : (typeof FeatureAbility !== 'undefined' ? FeatureAbility : wearengine);
                if (!api) {
                    starting = false;
                    startupReport('no messaging API');
                    startupReport = null;
                    return;
                }
                try {
                    api.subscribeMsg({ success: receive, fail: noop });
                } catch (e) {
                    starting = false;
                    startupReport('cannot subscribe');
                    startupReport = null;
                    return;
                }
                ready = true;
                var pending = queue;
                queue = [];
                for (var i = 0; i < pending.length; i++) {
                    deliver(pending[i]);
                }
                starting = false;
                startupReport('');
                startupReport = null;
            });
        });
    });
}

export default {
    start: start,
    listen: function (fn) {
        listener = fn;
    },
    send: function (message, done) {
        if (ready) {
            deliver({ message: message, done: done });
        } else {
            queue.push({ message: message, done: done });
        }
    }
};
