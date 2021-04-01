//
//  VoIPCenter.swift
//  flutter_ios_voip_kit
//
//  Created by 須藤将史 on 2020/07/02.
//

import Foundation
import Flutter
import PushKit
import CallKit
import AVFoundation

extension String {
    internal init(deviceToken: Data) {
        self = deviceToken.map { String(format: "%.2hhx", $0) }.joined()
    }
}

class VoIPCenter: NSObject {

    // MARK: - event channel

    private let eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?

    private enum EventChannel: String {
        case onDidReceiveIncomingPush
        case onDidAcceptIncomingCall
        case onDidRejectIncomingCall
        
        case onDidUpdatePushToken
        case onDidActivateAudioSession
        case onDidDeactivateAudioSession
    }

    // MARK: - PushKit

    private let didUpdateTokenKey = "Did_Update_VoIP_Device_Token"
    private let pushRegistry: PKPushRegistry

    var token: String? {
        if let didUpdateDeviceToken = UserDefaults.standard.data(forKey: didUpdateTokenKey) {
            let token = String(deviceToken: didUpdateDeviceToken)
            #if DEBUG
            print("🎈 VoIP didUpdateDeviceToken: \(token)")
            #endif
            return token
        }

        guard let cacheDeviceToken = self.pushRegistry.pushToken(for: .voIP) else {
            return nil
        }

        let token = String(deviceToken: cacheDeviceToken)
        #if DEBUG
        print("🎈 VoIP cacheDeviceToken: \(token)")
        #endif
        return token
    }

    // MARK: - CallKit

    let callKitCenter: CallKitCenter
    
    fileprivate var audioSessionMode: AVAudioSession.Mode
    fileprivate let ioBufferDuration: TimeInterval
    fileprivate let audioSampleRate: Double

    init(eventChannel: FlutterEventChannel) {
        self.eventChannel = eventChannel
        self.pushRegistry = PKPushRegistry(queue: .main)
        self.pushRegistry.desiredPushTypes = [.voIP]
        self.callKitCenter = CallKitCenter()
        
        if let path = Bundle.main.path(forResource: "Info", ofType: "plist"), let plist = NSDictionary(contentsOfFile: path) {
            self.audioSessionMode = ((plist["FIVKAudioSessionMode"] as? String) ?? "audio") == "video" ? .videoChat : .voiceChat
            self.ioBufferDuration = plist["FIVKIOBufferDuration"] as? TimeInterval ?? 0.005
            self.audioSampleRate = plist["FIVKAudioSampleRate"] as? Double ?? 44100.0
        } else {
            self.audioSessionMode = .voiceChat
            self.ioBufferDuration = TimeInterval(0.005)
            self.audioSampleRate = 44100.0
        }
        
        super.init()
        self.eventChannel.setStreamHandler(self)
        self.pushRegistry.delegate = self
        self.callKitCenter.setup(delegate: self)
    }
}

extension VoIPCenter: PKPushRegistryDelegate {

    // MARK: - PKPushRegistryDelegate

    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        #if DEBUG
        print("🎈 VoIP didUpdate pushCredentials")
        #endif
        UserDefaults.standard.set(pushCredentials.token, forKey: didUpdateTokenKey)
        
        self.eventSink?(["event": EventChannel.onDidUpdatePushToken.rawValue,
                         "token": pushCredentials.token.hexString])
    }
    
    // NOTE: iOS10 support

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        #if DEBUG
        print("🎈 VoIP didReceiveIncomingPushWith: \(payload.dictionaryPayload)")
        #endif

        _pushRegistry(parametersdidReceiveIncomingPushWith: payload, for: type, completion: {})
    }

    // NOTE: iOS11 or more support

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        #if DEBUG
        print("🎈 VoIP didReceiveIncomingPushWith completion: \(payload.dictionaryPayload)")
        #endif

        _pushRegistry(parametersdidReceiveIncomingPushWith: payload, for: type, completion: completion)
    }

    func _pushRegistry(parametersdidReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        let info = self.parse(payload: payload)
        let uuid = info?["uuid"] as! String
        let callerId = info?["incoming_caller_id"] as! String
        let callerName = info?["incoming_caller_name"] as! String
        let callState = info?["incoming_call_state"] as! String

        #if DEBUG
        print("🎈 VoIP _pushRegistry callState: \(callState)")
        #endif
        
        if (callState != "terminated") {
            self.callKitCenter.incomingCall(uuidString: uuid, callerId: callerId, callerName: callerName) { error in
                if let error = error {
                    #if DEBUG
                    print("❌ reportNewIncomingCall error: \(error.localizedDescription)")
                    #endif
                    return
                }
                self.eventSink?(["event": EventChannel.onDidReceiveIncomingPush.rawValue,
                                 "payload": info as Any,
                                 "incoming_caller_name": callerName])
                completion()
            }
        } else if (callState == "terminated") {
            self.callKitCenter.terminatedIncomingCall()
        }
    }

    private func parse(payload: PKPushPayload) -> [String: Any]? {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload.dictionaryPayload, options: .prettyPrinted)
            let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            let aps = json?["aps"] as? [String: Any]
            return aps?["alert"] as? [String: Any]
        } catch let error as NSError {
            #if DEBUG
            print("❌ VoIP parsePayload: \(error.localizedDescription)")
            #endif
            return nil
        }
    }
}

extension VoIPCenter: CXProviderDelegate {

    // MARK:  - CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        #if DEBUG
        print("🚫 VoIP providerDidReset")
        #endif
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        #if DEBUG
        print("🤙 VoIP CXStartCallAction")
        #endif
        self.callKitCenter.connectingOutgoingCall()
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        #if DEBUG
        print("✅ VoIP CXAnswerCallAction")
        #endif
        self.callKitCenter.answerCallAction = action
        self.configureAudioSession()
        self.eventSink?(["event": EventChannel.onDidAcceptIncomingCall.rawValue,
                         "uuid": self.callKitCenter.uuidString as Any,
                         "incoming_caller_id": self.callKitCenter.incomingCallerId as Any])
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        #if DEBUG
        print("❎ VoIP CXEndCallAction")
        #endif
        if (self.callKitCenter.isCalleeBeforeAcceptIncomingCall) {
            self.eventSink?(["event": EventChannel.onDidRejectIncomingCall.rawValue,
                             "uuid": self.callKitCenter.uuidString as Any,
                             "incoming_caller_id": self.callKitCenter.incomingCallerId as Any])
        }

        self.callKitCenter.disconnected(reason: .remoteEnded)
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        #if DEBUG
        print("🔈 VoIP didActivate audioSession")
        #endif
        self.eventSink?(["event": EventChannel.onDidActivateAudioSession.rawValue])
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        #if DEBUG
        print("🔇 VoIP didDeactivate audioSession")
        #endif
        self.eventSink?(["event": EventChannel.onDidDeactivateAudioSession.rawValue])
    }
    
    // This is a workaround for known issue, when audio doesn't start from lockscreen call
    // https://stackoverflow.com/questions/55391026/no-sound-after-connecting-to-webrtc-when-app-is-launched-in-background-using-pus
    private func configureAudioSession() {
        let sharedSession = AVAudioSession.sharedInstance()
        do {
            try sharedSession.setCategory(.playAndRecord,
                                          options: [AVAudioSession.CategoryOptions.allowBluetooth,
                                                    AVAudioSession.CategoryOptions.defaultToSpeaker])
            try sharedSession.setMode(audioSessionMode)
            try sharedSession.setPreferredIOBufferDuration(ioBufferDuration)
            try sharedSession.setPreferredSampleRate(audioSampleRate)
        } catch {
            #if DEBUG
            print("❌ VoIP Failed to configure `AVAudioSession`")
            #endif
        }
    }
}

extension VoIPCenter: FlutterStreamHandler {

    // MARK: - FlutterStreamHandler（event channel）

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
