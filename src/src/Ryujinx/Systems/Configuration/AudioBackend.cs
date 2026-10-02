using System.Text.Json.Serialization;

namespace Ryujinx.Ava.Systems.Configuration
{
    [JsonConverter(typeof(JsonStringEnumConverter<AudioBackend>))]
    public enum AudioBackend
    {
        Dummy,
        OpenAl,
        SoundIo,
        SDL3,
        AVFoundation,
        AudioToolbox = AVFoundation,
        SDL2 = SDL3
    }
}
