namespace Ryujinx.Audio.Backends.Apple
{
    class AppleAudioBuffer
    {
        public readonly ulong DriverIdentifier;
        public readonly ulong SampleCount;
        public readonly nint NativeBuffer;
        public ulong SamplePlayed;

        public AppleAudioBuffer(ulong driverIdentifier, ulong sampleCount, nint nativeBuffer)
        {
            DriverIdentifier = driverIdentifier;
            SampleCount = sampleCount;
            NativeBuffer = nativeBuffer;
            SamplePlayed = 0;
        }
    }
}
