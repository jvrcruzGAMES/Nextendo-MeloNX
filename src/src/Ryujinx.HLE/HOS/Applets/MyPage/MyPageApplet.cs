using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Services.Am.AppletAE;
using System;

namespace Ryujinx.HLE.HOS.Applets.MyPage
{
    /// <summary>
    /// The friend-invitation part of MyPage: shows the host's friend picker and reports whether the
    /// invitation was sent. Other MyPage screens are answered as cancelled.
    /// </summary>
    internal class MyPageApplet : IApplet
    {
        private const uint ResultCancelled = 0xFFFFFFFF;

        private readonly Horizon _system;

        public event EventHandler AppletStateChanged;

        public MyPageApplet(Horizon system)
        {
            _system = system;
        }

        public ResultCode Start(AppletSession normalSession, AppletSession interactiveSession)
        {
            normalSession.TryPop(out _); // CommonArguments
            if (!normalSession.TryPop(out byte[] argument))
            {
                argument = [];
            }

            ulong titleId = _system.Device.Processes.ActiveApplication?.ProgramId ?? 0;
            FriendInvitationRequest request = FriendInvitationRequest.Decode(argument, titleId);
            if (request == null)
            {
                Logger.Warning?.Print(LogClass.ServiceAm, $"MyPage request not supported ({argument.Length} bytes)");
            }

            bool sent = request != null && _system.Device.UIHandler.DisplayFriendInvitationDialog(request);

            normalSession.Push(BitConverter.GetBytes(sent ? 0u : ResultCancelled));

            AppletStateChanged?.Invoke(this, null);

            _system.ReturnFocus();

            return ResultCode.Success;
        }
    }
}
