using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Memory;
using System;
using System.Collections.Concurrent;
using System.Threading;
using System.Runtime.Versioning;
using Ryujinx.Audio.Backends.Apple.Native;
using static Ryujinx.Audio.Integration.IHardwareDeviceDriver;

namespace Ryujinx.Audio.Backends.Apple
{
    [SupportedOSPlatform("macos")]
    [SupportedOSPlatform("ios")]
    public sealed class AppleHardwareDeviceDriver : IHardwareDeviceDriver
    {
        private readonly ManualResetEvent _updateRequiredEvent;
        private readonly ManualResetEvent _pauseEvent;
        private readonly ConcurrentDictionary<AppleHardwareDeviceSession, byte> _sessions;
        private float _volume;

        public float Volume
        {
            get => _volume;
            set
            {
                _volume = value;

                foreach (AppleHardwareDeviceSession session in _sessions.Keys)
                {
                    session.UpdateEffectiveVolume();
                }
            }
        }

        public AppleHardwareDeviceDriver()
        {
            _updateRequiredEvent = new ManualResetEvent(false);
            _pauseEvent = new ManualResetEvent(true);
            _sessions = new ConcurrentDictionary<AppleHardwareDeviceSession, byte>();

            Volume = 1f;
        }

        public static bool IsSupported => OperatingSystem.IsMacOSVersionAtLeast(10, 10) || OperatingSystem.IsIOSVersionAtLeast(8, 0);

        public ManualResetEvent GetUpdateRequiredEvent()
            => _updateRequiredEvent;

        public ManualResetEvent GetPauseEvent()
            => _pauseEvent;

        public IHardwareDeviceSession OpenDeviceSession(Direction direction, IVirtualMemoryManager memoryManager,
            SampleFormat sampleFormat, uint sampleRate, uint channelCount)
        {
            if (channelCount == 0)
            {
                channelCount = 2;
            }

            if (sampleRate == 0)
            {
                sampleRate = Constants.TargetSampleRate;
            }

            if (direction != Direction.Output)
            {
                throw new NotImplementedException("Input direction is currently not implemented on Apple backend!");
            }

            AppleHardwareDeviceSession session = new(this, memoryManager, sampleFormat, sampleRate, channelCount);

            _sessions.TryAdd(session, 0);

            return session;
        }

        internal bool Unregister(AppleHardwareDeviceSession session)
            => _sessions.TryRemove(session, out _);

        internal static AVFoundation.AVAudioCommonFormat GetAudioFormat(SampleFormat sampleFormat)
        {
            return sampleFormat switch
            {
                SampleFormat.PcmFloat => AVFoundation.AVAudioCommonFormat.PcmFormatFloat32,
                _ => throw new ArgumentException($"Unsupported sample format {sampleFormat}"),
            };
        }

        public void Dispose()
        {
            GC.SuppressFinalize(this);
            Dispose(true);
        }

        private void Dispose(bool disposing)
        {
            if (disposing)
            {
                foreach (AppleHardwareDeviceSession session in _sessions.Keys)
                {
                    session.Dispose();
                }

                _pauseEvent.Dispose();
            }
        }

        public bool SupportsDirection(Direction direction)
            => direction != Direction.Input;

        public bool SupportsSampleRate(uint sampleRate) => true;

        public bool SupportsSampleFormat(SampleFormat sampleFormat)
            => sampleFormat == SampleFormat.PcmFloat;

        public bool SupportsChannelCount(uint channelCount)
            => channelCount is 1 or 2 || (channelCount == 6 && OperatingSystem.IsMacOS());
    }
}
