using Ryujinx.Common.Memory;
using System;
using System.Net;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Ryujinx.HLE.HOS.Services.Sockets.Sfdnsres.Types
{
    // [Nextendo] Packed getaddrinfo sockaddr — Mythrax bug #1 fix (getaddrinfo ai_addr packing).
    // The ONLY real bug was sin_len: it was sizeof(Array4)=4 instead of the full sockaddr size (16).
    // With sin_len=4 the guest resolver treated the sockaddr as 4 bytes and grpc never read the address
    // -> it built the connect sockaddr with a zero address -> connect to 0.0.0.0 ("port ok, addr 0").
    // Proof (grpc's actual connect sockaddr, captured): once sin_len=16, grpc DOES read the address and
    // maps the IPv4 result into an IPv4-mapped IPv6 sockaddr_in6 for its dual-stack socket:
    //     00 1C <port> <flowinfo> ::ffff:<addr> <scope>
    // and it reads our sin_port/sin_addr as HOST (little-endian) then applies htons/htonl — i.e. it
    // byte-swaps them once. So the wire bytes must be HOST-order (the value read little-endian), NOT
    // network order. The original code already produced host-order bytes (ctor HostToNetworkOrder + a
    // second swap in ToNetworkOrder); do NOT "fix" that to network order (that made grpc connect to the
    // address with its four bytes reversed, and the game crashed). Only sin_len needed correcting.
    [StructLayout(LayoutKind.Sequential, Pack = 1, Size = 0x10)]
    struct AddrInfo4
    {
        public byte Length;
        public byte Family;
        public short Port;
        public Array4<byte> Address;
        public Array8<byte> Padding;

        public AddrInfo4(IPAddress address, short port)
        {
            Length = (byte)Unsafe.SizeOf<AddrInfo4>(); // 16 (was sizeof(Array4)=4 — the bug)
            Family = (byte)AddressFamily.InterNetwork;
            Port = IPAddress.HostToNetworkOrder(port);
            Address = new Array4<byte>();

            address.TryWriteBytes(Address.AsSpan(), out _);
        }

        public void ToNetworkOrder()
        {
            Port = IPAddress.HostToNetworkOrder(Port);

            RawIpv4AddressNetworkEndianSwap(Address.AsSpan());
        }

        public void ToHostOrder()
        {
            Port = IPAddress.NetworkToHostOrder(Port);

            RawIpv4AddressNetworkEndianSwap(Address.AsSpan());
        }

        public static void RawIpv4AddressNetworkEndianSwap(Span<byte> address)
        {
            if (BitConverter.IsLittleEndian)
            {
                address.Reverse();
            }
        }
    }
}
