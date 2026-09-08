// Bounded research helper; does not change macOS default input/output devices.
// swiftc tools/audio-probe.swift -o .build/audio-probe
// .build/audio-probe list
// .build/audio-probe play DEVICE_UID FILE [GAIN_0_TO_1]
import Foundation
import AppKit
import CoreAudio

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
          let value else { return "" }
    return value.takeRetainedValue() as String
}
func streams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
    return Int(size) / MemoryLayout<AudioStreamID>.size
}
func devices() -> [(AudioDeviceID, String, String)] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { fail("Cannot enumerate audio devices") }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { fail("Cannot read audio devices") }
    return ids.map { ($0, stringProperty($0,kAudioObjectPropertyName), stringProperty($0,kAudioDevicePropertyDeviceUID)) }
}
let args = Array(CommandLine.arguments.dropFirst())
let available = devices()
if args == ["list"] {
    let rows = available.map { id,name,uid in
        ["id":id,"name":name,"uid":uid,"input_streams":streams(id,kAudioDevicePropertyScopeInput),"output_streams":streams(id,kAudioDevicePropertyScopeOutput)] as [String:Any]
    }
    let data = try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys])
    print(String(decoding:data,as:UTF8.self))
} else if args.first == "play", (3...4).contains(args.count) {
    guard let target = available.first(where:{$0.2 == args[1]}), streams(target.0,kAudioDevicePropertyScopeOutput)>0 else { fail("Selected output UID is not available") }
    guard target.1.lowercased().contains("ditoo") else { fail("This probe targets Ditoo output only") }
    let gain = args.count == 4 ? Float(args[3]) : 0.2
    guard let gain, gain.isFinite, (0...1).contains(gain) else { fail("Gain must be 0...1") }
    guard let sound = NSSound(contentsOf:URL(fileURLWithPath:args[2]),byReference:true) else { fail("Cannot open audio file") }
    guard sound.duration > 0, sound.duration <= 30 else { fail("Probe playback is limited to 30 seconds") }
    sound.playbackDeviceIdentifier = args[1]
    sound.volume = gain
    guard sound.play() else { fail("NSSound could not start playback") }
    print("Playback requested on \(target.1), UID=\(args[1]), gain=\(gain), duration=\(sound.duration)s")
    fflush(stdout)
    let deadline = Date().addingTimeInterval(sound.duration + 5)
    repeat { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) } while sound.isPlaying && Date() < deadline
    let finished = !sound.isPlaying
    sound.stop()
    if !finished { fail("Playback deadline exceeded") }
    print("Playback ended; physical audio requires listener confirmation.")
} else {
    fail("Usage: audio-probe list | play DEVICE_UID FILE [GAIN]")
}
