using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Backends.Apple.Native
{
    internal static unsafe partial class AVFoundation
    {
        private const string ObjCRuntime = "/usr/lib/libobjc.A.dylib";
        private const string LibSystem = "/usr/lib/libSystem.B.dylib";
        private const string AVFoundationFramework = "/System/Library/Frameworks/AVFoundation.framework/AVFoundation";

        private const int BlockHasSignature = 1 << 30;
        private const uint AudioChannelLayoutTagMpeg51A = (121u << 16) | 6u;

        private static readonly nint _nsConcreteStackBlock;

        static AVFoundation()
        {
            NativeLibrary.Load(AVFoundationFramework);

            nint libSystem = NativeLibrary.Load(LibSystem);
            _nsConcreteStackBlock = NativeLibrary.GetExport(libSystem, "_NSConcreteStackBlock");
        }

        internal enum AVAudioCommonFormat : ulong
        {
            PcmFormatFloat32 = 1,
            PcmFormatInt16 = 3,
            PcmFormatInt32 = 4,
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct AudioBuffer
        {
            public uint NumberChannels;
            public uint DataByteSize;
            public nint Data;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct AudioBufferList
        {
            public uint NumberBuffers;
            public AudioBuffer Buffer;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BlockDescriptor
        {
            public nuint Reserved;
            public nuint Size;
            public nint Signature;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BlockLiteral
        {
            public nint Isa;
            public int Flags;
            public int Reserved;
            public nint Invoke;
            public nint Descriptor;
            public nint Context;
        }

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate void CompletionCallback(nint block);

        [LibraryImport(ObjCRuntime, StringMarshalling = StringMarshalling.Utf8)]
        private static partial nint objc_getClass(string name);

        [LibraryImport(ObjCRuntime, StringMarshalling = StringMarshalling.Utf8)]
        private static partial nint sel_getUid(string name);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        private static partial void void_objc_msgSend(nint receiver, nint selector);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        private static partial void void_objc_msgSend_nint(nint receiver, nint selector, nint value);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        private static partial void void_objc_msgSend_float(nint receiver, nint selector, float value);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        private static partial void void_objc_msgSend_uint(nint receiver, nint selector, uint value);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        private static partial void void_objc_msgSend_nint_nint(nint receiver, nint selector, nint value0, nint value1);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        private static partial void void_objc_msgSend_nint_nint_nint(nint receiver, nint selector, nint value0, nint value1, nint value2);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        private static partial nint nint_objc_msgSend(nint receiver, nint selector);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        private static partial nint nint_objc_msgSend_nint(nint receiver, nint selector, nint value);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        private static partial nint nint_objc_msgSend_nint_uint(nint receiver, nint selector, nint value, uint frameCapacity);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        private static partial nint nint_objc_msgSend_uint(nint receiver, nint selector, uint value);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        private static partial nint nint_objc_msgSend_format(nint receiver, nint selector, AVAudioCommonFormat commonFormat, double sampleRate, uint channels, byte interleaved);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        private static partial nint nint_objc_msgSend_format_layout(nint receiver, nint selector, AVAudioCommonFormat commonFormat, double sampleRate, byte interleaved, nint channelLayout);

        [LibraryImport(ObjCRuntime, EntryPoint = "objc_msgSend")]
        [return: MarshalAs(UnmanagedType.I1)]
        private static partial bool bool_objc_msgSend_out_nint(nint receiver, nint selector, out nint value);

        internal static nint GetClass(string name)
        {
            return objc_getClass(name);
        }

        internal static nint GetSelector(string name)
        {
            return sel_getUid(name);
        }

        internal static nint Alloc(string className)
        {
            return nint_objc_msgSend(GetClass(className), GetSelector("alloc"));
        }

        internal static nint Init(nint receiver)
        {
            return nint_objc_msgSend(receiver, GetSelector("init"));
        }

        internal static nint InitAudioFormat(nint receiver, AVAudioCommonFormat commonFormat, double sampleRate, uint channels)
        {
            // The channel-count initializer returns nil for formats with more than two channels.
            // Six-channel audio therefore needs an explicit layout.
            if (channels == 6)
            {
                nint channelLayout = nint_objc_msgSend_uint(
                    Alloc("AVAudioChannelLayout"),
                    GetSelector("initWithLayoutTag:"),
                    AudioChannelLayoutTagMpeg51A);

                if (channelLayout == nint.Zero)
                {
                    Release(receiver);

                    return nint.Zero;
                }

                nint format = nint_objc_msgSend_format_layout(
                    receiver,
                    GetSelector("initWithCommonFormat:sampleRate:interleaved:channelLayout:"),
                    commonFormat,
                    sampleRate,
                    0,
                    channelLayout);

                Release(channelLayout);

                return format;
            }

            return nint_objc_msgSend_format(
                receiver,
                GetSelector("initWithCommonFormat:sampleRate:channels:interleaved:"),
                commonFormat,
                sampleRate,
                channels,
                0);
        }

        internal static nint InitPcmBuffer(nint receiver, nint format, uint frameCapacity)
        {
            return nint_objc_msgSend_nint_uint(receiver, GetSelector("initWithPCMFormat:frameCapacity:"), format, frameCapacity);
        }

        internal static void AttachNode(nint engine, nint node)
        {
            void_objc_msgSend_nint(engine, GetSelector("attachNode:"), node);
        }

        internal static nint MainMixerNode(nint engine)
        {
            return nint_objc_msgSend(engine, GetSelector("mainMixerNode"));
        }

        internal static void Connect(nint engine, nint node, nint targetNode, nint format)
        {
            void_objc_msgSend_nint_nint_nint(engine, GetSelector("connect:to:format:"), node, targetNode, format);
        }

        internal static void Prepare(nint engine)
        {
            void_objc_msgSend(engine, GetSelector("prepare"));
        }

        internal static bool Start(nint engine, out nint error)
        {
            return bool_objc_msgSend_out_nint(engine, GetSelector("startAndReturnError:"), out error);
        }

        internal static void Play(nint playerNode)
        {
            void_objc_msgSend(playerNode, GetSelector("play"));
        }

        internal static void Pause(nint playerNode)
        {
            void_objc_msgSend(playerNode, GetSelector("pause"));
        }

        internal static void Stop(nint playerNode)
        {
            void_objc_msgSend(playerNode, GetSelector("stop"));
        }

        internal static void SetVolume(nint playerNode, float volume)
        {
            void_objc_msgSend_float(playerNode, GetSelector("setVolume:"), volume);
        }

        internal static void SetFrameLength(nint pcmBuffer, uint frameLength)
        {
            void_objc_msgSend_uint(pcmBuffer, GetSelector("setFrameLength:"), frameLength);
        }

        internal static AudioBufferList* GetMutableAudioBufferList(nint pcmBuffer)
        {
            return (AudioBufferList*)nint_objc_msgSend(pcmBuffer, GetSelector("mutableAudioBufferList"));
        }

        internal static void ScheduleBuffer(nint playerNode, nint pcmBuffer, nint completionHandler)
        {
            void_objc_msgSend_nint_nint(playerNode, GetSelector("scheduleBuffer:completionHandler:"), pcmBuffer, completionHandler);
        }

        internal static void Release(nint obj)
        {
            if (obj != nint.Zero)
            {
                void_objc_msgSend(obj, GetSelector("release"));
            }
        }

        internal static nint CreateCompletionBlock(nint context, CompletionCallback callback, out GCHandle callbackHandle)
        {
            callbackHandle = GCHandle.Alloc(callback);

            nint descriptor = Marshal.AllocHGlobal(sizeof(BlockDescriptor));
            nint block = Marshal.AllocHGlobal(sizeof(BlockLiteral));
            nint signature = Marshal.StringToHGlobalAnsi("v@?");

            *(BlockDescriptor*)descriptor = new BlockDescriptor
            {
                Reserved = 0,
                Size = (nuint)sizeof(BlockLiteral),
                Signature = signature,
            };

            *(BlockLiteral*)block = new BlockLiteral
            {
                Isa = _nsConcreteStackBlock,
                Flags = BlockHasSignature,
                Reserved = 0,
                Invoke = Marshal.GetFunctionPointerForDelegate(callback),
                Descriptor = descriptor,
                Context = context,
            };

            return block;
        }

        internal static nint GetBlockContext(nint block)
        {
            return ((BlockLiteral*)block)->Context;
        }

        internal static void DestroyCompletionBlock(nint block, GCHandle callbackHandle)
        {
            if (block == nint.Zero)
            {
                return;
            }

            BlockLiteral* literal = (BlockLiteral*)block;
            BlockDescriptor* descriptor = (BlockDescriptor*)literal->Descriptor;

            Marshal.FreeHGlobal(descriptor->Signature);
            Marshal.FreeHGlobal(literal->Descriptor);
            Marshal.FreeHGlobal(block);

            if (callbackHandle.IsAllocated)
            {
                callbackHandle.Free();
            }
        }
    }
}
