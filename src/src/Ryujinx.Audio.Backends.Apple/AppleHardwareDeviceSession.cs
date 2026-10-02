using Ryujinx.Audio.Backends.Apple.Native;
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using Ryujinx.Common.Logging;
using Ryujinx.Memory;
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Threading;

namespace Ryujinx.Audio.Backends.Apple
{
    [SupportedOSPlatform("macos")]
    [SupportedOSPlatform("ios")]
    sealed unsafe class AppleHardwareDeviceSession : HardwareDeviceSessionOutputBase
    {
        private readonly AppleHardwareDeviceDriver _driver;
        private readonly ConcurrentQueue<AppleAudioBuffer> _queuedBuffers;
        private readonly ManualResetEvent _updateRequiredEvent;
        private readonly int _bytesPerFrame;
        private readonly object _lock;

        private readonly AVFoundation.CompletionCallback _completionCallback;
        private readonly GCHandle _gcHandle;
        private readonly GCHandle _completionCallbackHandle;

        private nint _engine;
        private nint _playerNode;
        private nint _format;
        private nint _completionBlock;

        private ulong _playedSampleCount;
        private bool _started;
        private bool _disposed;
        private float _volume;

        public AppleHardwareDeviceSession(
            AppleHardwareDeviceDriver driver,
            IVirtualMemoryManager memoryManager,
            SampleFormat requestedSampleFormat,
            uint requestedSampleRate,
            uint requestedChannelCount)
            : base(memoryManager, requestedSampleFormat, requestedSampleRate, requestedChannelCount)
        {
            _driver = driver;
            _queuedBuffers = new ConcurrentQueue<AppleAudioBuffer>();
            _updateRequiredEvent = driver.GetUpdateRequiredEvent();
            _bytesPerFrame = BackendHelper.GetSampleSize(requestedSampleFormat) * (int)requestedChannelCount;
            _lock = new object();
            _completionCallback = OnBufferCompleted;
            _gcHandle = GCHandle.Alloc(this);
            _completionBlock = AVFoundation.CreateCompletionBlock(GCHandle.ToIntPtr(_gcHandle), _completionCallback, out _completionCallbackHandle);
            _volume = 1f;

            SetupAudioEngine();
        }

        private void SetupAudioEngine()
        {
            lock (_lock)
            {
                _engine = AVFoundation.Init(AVFoundation.Alloc("AVAudioEngine"));
                _playerNode = AVFoundation.Init(AVFoundation.Alloc("AVAudioPlayerNode"));
                _format = AVFoundation.InitAudioFormat(
                    AVFoundation.Alloc("AVAudioFormat"),
                    AppleHardwareDeviceDriver.GetAudioFormat(RequestedSampleFormat),
                    RequestedSampleRate,
                    RequestedChannelCount);

                if (_engine == nint.Zero || _playerNode == nint.Zero || _format == nint.Zero)
                {
                    throw new InvalidOperationException("Failed to initialize AVFoundation audio objects.");
                }

                AVFoundation.AttachNode(_engine, _playerNode);
                AVFoundation.Connect(_engine, _playerNode, AVFoundation.MainMixerNode(_engine), _format);
                AVFoundation.Prepare(_engine);

                if (!AVFoundation.Start(_engine, out nint error))
                {
                    string errorMessage = error != nint.Zero ? $" Error object: 0x{error:x}." : string.Empty;

                    throw new InvalidOperationException($"AVAudioEngine failed to start.{errorMessage}");
                }

                UpdateEffectiveVolume();
            }
        }

        private static void OnBufferCompleted(nint block)
        {
            nint context = AVFoundation.GetBlockContext(block);

            if (context == nint.Zero)
            {
                return;
            }

            if (GCHandle.FromIntPtr(context).Target is AppleHardwareDeviceSession session)
            {
                session.CompleteQueuedBuffer();
            }
        }

        private void CompleteQueuedBuffer()
        {
            if (_disposed)
            {
                return;
            }

            if (_queuedBuffers.TryDequeue(out AppleAudioBuffer buffer))
            {
                ulong remainingSamples = buffer.SampleCount - Interlocked.Read(ref buffer.SamplePlayed);

                Interlocked.Add(ref buffer.SamplePlayed, remainingSamples);
                Interlocked.Add(ref _playedSampleCount, remainingSamples);

                AVFoundation.Release(buffer.NativeBuffer);

                _updateRequiredEvent.Set();
            }
        }

        private nint CreatePcmBuffer(AudioBuffer buffer, ulong sampleCount)
        {
            uint frameCount = checked((uint)sampleCount);
            nint pcmBuffer = AVFoundation.InitPcmBuffer(AVFoundation.Alloc("AVAudioPCMBuffer"), _format, frameCount);

            if (pcmBuffer == nint.Zero)
            {
                throw new InvalidOperationException("Failed to allocate AVAudioPCMBuffer.");
            }

            try
            {
                AVFoundation.SetFrameLength(pcmBuffer, frameCount);

                AVFoundation.AudioBufferList* bufferList = AVFoundation.GetMutableAudioBufferList(pcmBuffer);
                uint actualBufferCount = bufferList == null ? 0 : bufferList->NumberBuffers;

                if (actualBufferCount != RequestedChannelCount)
                {
                    throw new InvalidOperationException(
                        $"AVAudioPCMBuffer returned an unexpected buffer count. Expected {RequestedChannelCount}, got {actualBufferCount}.");
                }

                ReadOnlySpan<float> interleavedSamples = MemoryMarshal.Cast<byte, float>(buffer.Data);
                int channelCount = checked((int)RequestedChannelCount);
                int frames = checked((int)frameCount);
                int bytesPerChannel = checked(frames * sizeof(float));
                AVFoundation.AudioBuffer* nativeBuffers = &bufferList->Buffer;

                for (int channel = 0; channel < channelCount; channel++)
                {
                    AVFoundation.AudioBuffer* nativeBuffer = &nativeBuffers[channel];

                    if (nativeBuffer->Data == nint.Zero || nativeBuffer->DataByteSize < (uint)bytesPerChannel)
                    {
                        throw new InvalidOperationException(
                            $"AVAudioPCMBuffer channel {channel} is too small. Expected {bytesPerChannel} bytes, got {nativeBuffer->DataByteSize} bytes.");
                    }

                    Span<float> channelSamples = new((void*)nativeBuffer->Data, frames);

                    for (int frame = 0; frame < frames; frame++)
                    {
                        channelSamples[frame] = interleavedSamples[(frame * channelCount) + channel];
                    }

                    nativeBuffer->DataByteSize = (uint)bytesPerChannel;
                }

                return pcmBuffer;
            }
            catch
            {
                AVFoundation.Release(pcmBuffer);

                throw;
            }
        }

        public void UpdateEffectiveVolume()
        {
            lock (_lock)
            {
                if (_playerNode != nint.Zero && !_disposed)
                {
                    AVFoundation.SetVolume(_playerNode, Math.Clamp(_driver.Volume * _volume, 0f, 1f));
                }
            }
        }

        public override void QueueBuffer(AudioBuffer buffer)
        {
            if (_disposed)
            {
                return;
            }

            if (buffer.Data == null || buffer.Data.Length == 0 || buffer.Data.Length % _bytesPerFrame != 0)
            {
                throw new ArgumentException("Audio buffer does not contain a whole number of PCM frames.", nameof(buffer));
            }

            ulong sampleCount = (ulong)GetSampleCount(buffer.Data.Length);
            nint pcmBuffer = CreatePcmBuffer(buffer, sampleCount);
            AppleAudioBuffer driverBuffer = new(buffer.DataPointer, sampleCount, pcmBuffer);

            _queuedBuffers.Enqueue(driverBuffer);
            AVFoundation.ScheduleBuffer(_playerNode, pcmBuffer, _completionBlock);
        }

        public override void Start()
        {
            lock (_lock)
            {
                if (_disposed || _started)
                {
                    return;
                }

                AVFoundation.Play(_playerNode);
                _started = true;
            }
        }

        public override void Stop()
        {
            lock (_lock)
            {
                if (_disposed || !_started)
                {
                    return;
                }

                AVFoundation.Pause(_playerNode);
                _started = false;
            }
        }

        public override ulong GetPlayedSampleCount()
            => Interlocked.Read(ref _playedSampleCount);

        public override float GetVolume() => _volume;

        public override void SetVolume(float volume)
        {
            _volume = volume;
            UpdateEffectiveVolume();
        }

        public override bool WasBufferFullyConsumed(AudioBuffer buffer)
        {
            if (!_queuedBuffers.TryPeek(out AppleAudioBuffer driverBuffer))
            {
                return true;
            }

            return driverBuffer.DriverIdentifier != buffer.DataPointer;
        }

        public override void PrepareToClose() { }

        public override void UnregisterBuffer(AudioBuffer buffer) { }

        private void ReleaseQueuedBuffers()
        {
            while (_queuedBuffers.TryDequeue(out AppleAudioBuffer buffer))
            {
                AVFoundation.Release(buffer.NativeBuffer);
            }
        }

        private void Dispose(bool disposing)
        {
            if (!disposing || !_driver.Unregister(this))
            {
                return;
            }

            lock (_lock)
            {
                _disposed = true;

                if (_playerNode != nint.Zero)
                {
                    AVFoundation.Stop(_playerNode);
                }

                ReleaseQueuedBuffers();

                AVFoundation.Release(_format);
                AVFoundation.Release(_playerNode);
                AVFoundation.Release(_engine);

                _format = nint.Zero;
                _playerNode = nint.Zero;
                _engine = nint.Zero;
            }

            AVFoundation.DestroyCompletionBlock(_completionBlock, _completionCallbackHandle);
            _completionBlock = nint.Zero;

            if (_gcHandle.IsAllocated)
            {
                _gcHandle.Free();
            }

            Logger.Debug?.Print(LogClass.Audio, "Disposed AVFoundation audio session.");
        }

        public override void Dispose()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
        }
    }
}
