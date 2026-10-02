using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using System;
using System.IO;

namespace Ryujinx.Ava.Common
{
    /// <summary>
    /// [Nextendo] Whether in-game friend notifications (toasts) are shown. Persisted as a tiny flag
    /// file next to the other per-user Nextendo state, so the choice survives across launches. Enabled
    /// by default; a "notifications off" file is written only when the player turns them off.
    /// </summary>
    public static class NextendoNotificationSettings
    {
        private const string FlagFileName = "nextendo_notifications_off";

        private static string FlagPath => Path.Combine(AppDataManager.BaseDirPath, FlagFileName);

        private static bool? _cached;

        public static bool Enabled
        {
            get
            {
                if (_cached is null)
                {
                    try
                    {
                        _cached = !File.Exists(FlagPath);
                    }
                    catch
                    {
                        _cached = true;
                    }
                }

                return _cached.Value;
            }
            set
            {
                _cached = value;

                try
                {
                    if (value)
                    {
                        if (File.Exists(FlagPath))
                        {
                            File.Delete(FlagPath);
                        }
                    }
                    else
                    {
                        File.WriteAllText(FlagPath, "1");
                    }
                }
                catch (Exception ex)
                {
                    Logger.Warning?.Print(LogClass.Application, $"[Nextendo] could not persist notification setting: {ex.Message}");
                }
            }
        }
    }
}
