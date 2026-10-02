using System;
using System.Buffers.Binary;

namespace Ryujinx.HLE.HOS.Applets.MyPage
{
    /// <summary>
    /// A game's "invite friends" request (MyPage modes 8 and 9, 9.0.0+ argument layout).
    /// </summary>
    public class FriendInvitationRequest
    {
        public uint Mode { get; private init; }
        public uint RecipientLimit { get; private init; }
        public ulong[] AccountIds { get; private init; } = [];
        public byte[] UserData { get; private init; } = [];
        public byte[] Description { get; private init; } = [];
        public ulong TitleId { get; init; }

        private const int DescriptionSize = 0xC00;
        private const int MaxUserDataSize = 0x400;

        // Null when the argument is truncated or asks for something other than sending an invite.
        public static FriendInvitationRequest Decode(ReadOnlySpan<byte> input, ulong titleId)
        {
            if (input.Length < 0x18)
            {
                return null;
            }

            uint mode = BinaryPrimitives.ReadUInt32LittleEndian(input);
            if (mode != 8 && mode != 9)
            {
                return null;
            }

            int sizeOffset = mode == 8 ? 0x20 : 0xA0;
            int dataOffset = sizeOffset + 8;
            int descriptionOffset = dataOffset + MaxUserDataSize;
            if (input.Length < descriptionOffset + DescriptionSize)
            {
                return null;
            }

            uint limit = BinaryPrimitives.ReadUInt32LittleEndian(input[0x18..]);
            ulong dataSize = BinaryPrimitives.ReadUInt64LittleEndian(input[sizeOffset..]);
            if (limit == 0 || limit > 16 || dataSize > MaxUserDataSize)
            {
                return null;
            }

            ulong[] accountIds = [];
            if (mode == 9)
            {
                accountIds = new ulong[limit];
                for (int i = 0; i < limit; i++)
                {
                    accountIds[i] = BinaryPrimitives.ReadUInt64LittleEndian(input[(0x20 + i * 8)..]);
                }
            }

            return new FriendInvitationRequest
            {
                Mode = mode,
                RecipientLimit = limit,
                AccountIds = accountIds,
                UserData = input.Slice(dataOffset, (int)dataSize).ToArray(),
                Description = input.Slice(descriptionOffset, DescriptionSize).ToArray(),
                TitleId = titleId,
            };
        }
    }
}
