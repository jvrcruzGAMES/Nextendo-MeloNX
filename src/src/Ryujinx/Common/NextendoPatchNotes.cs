using Avalonia.Controls;
using Avalonia.Media;
using FluentAvalonia.UI.Controls;
using Ryujinx.Ava.Common.Locale;
using Ryujinx.Ava.UI.Helpers;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using System;
using System.IO;
using System.Threading.Tasks;

namespace Ryujinx.Ava.Common
{
    /// <summary>
    /// [Nextendo] "What's new" popup, shown once per version on the first launch of a new build.
    ///
    /// A flag file records the version whose notes were last shown. When the running version differs
    /// (comparing the base version, ignoring any "+githash" suffix so a rebuild of the same release
    /// doesn't re-trigger it) the condensed notes are shown and the flag is updated. Deleting
    /// nextendo_patchnote_version re-shows them.
    /// </summary>
    public static class NextendoPatchNotes
    {
        private const string FlagFileName = "nextendo_patchnote_version";

        private static string FlagPath => Path.Combine(AppDataManager.BaseDirPath, FlagFileName);

        // The base version (before any "+githash"), so the note isn't re-shown just because the
        // hash changed within the same release.
        private static string CurrentVersion()
        {
            string v = Ryujinx.Common.ReleaseInformation.Version ?? "";
            int plus = v.IndexOf('+');

            return plus >= 0 ? v[..plus] : v;
        }

        /// <summary>True when the running version's notes haven't been shown on this install yet.</summary>
        public static bool ShouldShow()
        {
            try
            {
                string cur = CurrentVersion();
                if (string.IsNullOrEmpty(cur))
                {
                    return false;
                }

                string seen = File.Exists(FlagPath) ? File.ReadAllText(FlagPath).Trim() : "";

                return seen != cur;
            }
            catch
            {
                return false;
            }
        }

        /// <summary>
        /// Records the running version as "notes seen", so they won't show again until the next
        /// release. Also seeds the flag on a fresh install (no "what's new" the very first time,
        /// right after the setup wizard).
        /// </summary>
        public static void MarkShown()
        {
            try
            {
                File.WriteAllText(FlagPath, CurrentVersion());
            }
            catch (Exception ex)
            {
                Logger.Warning?.Print(LogClass.Application, $"[Nextendo] could not write patch-note flag: {ex.Message}");
            }
        }

        /// <summary>Shows the condensed patch notes as a modal dialog, then marks them seen.</summary>
        public static async Task ShowAsync()
        {
            try
            {
                TextBlock body = new()
                {
                    Text = LocaleManager.Instance[LocaleKeys.Dialog_Nextendo_PatchNoteBody],
                    TextWrapping = TextWrapping.Wrap,
                    FontSize = 14,
                };

                ContentDialog dialog = new()
                {
                    Title = LocaleManager.Instance[LocaleKeys.Dialog_Nextendo_PatchNoteTitle],
                    Content = new ScrollViewer { Content = body, MaxHeight = 420 },
                    CloseButtonText = LocaleManager.Instance[LocaleKeys.Dialog_Nextendo_PatchNoteButton],
                };

                await ContentDialogHelper.ShowAsync(dialog);
            }
            catch (Exception ex)
            {
                Logger.Warning?.Print(LogClass.UI, $"[Nextendo] patch-note popup failed: {ex.Message}");
            }
            finally
            {
                MarkShown();
            }
        }
    }
}
