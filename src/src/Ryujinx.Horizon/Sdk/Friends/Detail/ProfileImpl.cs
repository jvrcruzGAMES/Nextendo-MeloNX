using Ryujinx.Horizon.Sdk.Account;
using System.Runtime.InteropServices;

namespace Ryujinx.Horizon.Sdk.Friends.Detail
{
    // Offsets as nnSdk's Profile accessors read them.
    [StructLayout(LayoutKind.Explicit, Size = 0x100, Pack = 0x1)]
    struct ProfileImpl
    {
        [FieldOffset(0x00)]
        public NetworkServiceAccountId NetworkUserId;

        [FieldOffset(0x08)]
        public Nickname Nickname;

        [FieldOffset(0x30)]
        public Url ImageUrl;

        [FieldOffset(0xD0)]
        public byte IsValid;
    }
}
